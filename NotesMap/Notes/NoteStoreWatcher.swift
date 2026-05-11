// NoteStoreWatcher.swift: File-System-Watch auf NoteStore.sqlite-wal.
//
// Apple Notes schreibt bei jeder Änderung (neue Notiz, Edit, Löschen, Move)
// in die WAL-Datei der SQLite-DB. Wir hängen uns per
// DispatchSource.makeFileSystemObjectSource an die WAL an und triggern nach
// einem Debounce-Fenster (default 1.5s) einen Callback.
//
// Warum WAL und nicht die Main-DB?
//   - WAL bekommt pro Commit einen .write/.extend-Event
//   - Main-DB wird seltener angefasst (nur beim Checkpoint)
//   - WAL-Rotation via SQLITE_FCNTL_PERSIST_WAL passiert, wir fangen
//     .rename/.delete ab und re-openen den Deskriptor.
//
// Threading: alle internen Arbeiten laufen auf einer serial queue.
// `onChange` wird garantiert auf MAIN aufgerufen.

import Foundation

final class NoteStoreWatcher {
    private let path: String
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceTimer: DispatchSourceTimer?
    private let queue: DispatchQueue

    init(
        path: String,
        debounce: TimeInterval = 1.5,
        onChange: @escaping () -> Void
    ) {
        self.path = path
        self.debounceInterval = debounce
        self.onChange = onChange
        self.queue = DispatchQueue(label: "NoteStoreWatcher", qos: .utility)
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Private (auf `queue`)

    private func startOnQueue() {
        stopOnQueue()

        // O_EVTONLY: Deskriptor nur für Events, kein Read/Write. Das ist
        // auch bei Full-Disk-Access-Restriktionen die sicherste Variante.
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor != -1 else {
            let err = String(cString: strerror(errno))
            NSLog("[NoteStoreWatcher] open(\(path)) fehlgeschlagen: \(err)")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self = self, let source = self.source else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                // WAL wurde rotiert/gelöscht → Deskriptor ist tot. Nach kurzer
                // Pause neu öffnen. Apple Notes rotiert WAL gelegentlich.
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startOnQueue()
                }
                return
            }
            self.scheduleDebounceOnQueue()
        }

        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor != -1 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        src.resume()
        self.source = src
    }

    private func stopOnQueue() {
        debounceTimer?.cancel()
        debounceTimer = nil
        source?.cancel()
        source = nil
    }

    private func scheduleDebounceOnQueue() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let callback = self.onChange
            DispatchQueue.main.async {
                callback()
            }
        }
        timer.resume()
        debounceTimer = timer
    }

    deinit {
        // Nicht die *OnQueue-Varianten aufrufen; deinit darf nicht auf
        // eine (evtl. schon nicht mehr existente) Queue dispatchen. Die
        // GCD-Sources haben ihre eigene Cleanup.
        source?.cancel()
        debounceTimer?.cancel()
    }
}
