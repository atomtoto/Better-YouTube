import CloudKit
import Combine
import Foundation
import Security

/// The JSON library remains usable offline. CloudKit holds one versioned record per list item,
/// including removals, and CKSyncEngine keeps its change tokens and upload queue across launches.
@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()
    /// The container the entitlements name. It follows the bundle identifier, which each
    /// developer may choose (see Config/Signing.xcconfig), so it is read from the Info.plist.
    static let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: "BYCloudKitContainer") as? String
        ?? "iCloud.com.atomtoto.BetterYouTube"
    static let zoneID = CKRecordZone.ID(zoneName: "BetterYouTubeLibrary")
    static let recordType = "LibraryEntry"
    static let enabledKey = "icloud_sync_enabled"
    static let preferenceKeys = [MiniPlayerStyle.storageKey, FloatingMiniPlayerSize.storageKey]

    @Published private(set) var isEnabled: Bool
    static let waitingMessage = String(localized: "Waiting for iCloud.")
    @Published private(set) var statusMessage = ICloudSyncService.waitingMessage
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing = false

    private struct Cache: Codable {
        var schemaVersion = 1
        var entries: [String: CloudSyncEntry] = [:]
        // An independent outbox closes the crash window between the library write and an
        // engine state update. Only a server acknowledgement removes an entry from it.
        var dirty: Set<String> = []
        var systemFields: [String: Data] = [:]
        var engineState: CKSyncEngine.State.Serialization?
        var accountID: String?
        var lastSyncDate: Date?
    }

    private var cache = Cache()
    private let library: LibraryStore
    private let playbackPositions: PlaybackPositionStore
    private let defaults: UserDefaults
    private let fileURL: URL
    private let cloudKitAvailable: () -> Bool
    private var engine: CKSyncEngine?
    private var starting = false
    private var generation = 0
    private var observations = Set<AnyCancellable>()
    private var preferenceValues: [String: String] = [:]
    private var applyingPreferences = false
    private var cacheIsWritable = true
    private var operationFailed = false
    private var activeOperations = 0
    private var resettingDevice = false

    private convenience init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(library: .shared, playbackPositions: .shared, defaults: .standard,
                  fileURL: folder.appendingPathComponent("BetterYouTube/icloud-sync.json"),
                  cloudKitAvailable: { Self.isEntitledForCloudKit })
    }

    /// Read once: on a phone it means reading the provisioning profile off disk.
    private static let isEntitledForCloudKit = hasCloudKitEntitlement()

    /// Whether this build may use iCloud at all. One signed by a free Apple developer account
    /// can't — Config/Signing.xcconfig leaves iCloud out for those — and Settings says so rather
    /// than offering a switch that does nothing.
    var isAvailable: Bool { cloudKitAvailable() }

    static var unavailableMessage: String {
        String(localized: "iCloud isn't available in this build: it was signed without iCloud, as a free Apple developer account requires. Your library stays on this device.")
    }

    /// Dependencies make the offline/reset path testable without an Apple account or entitlement.
    ///
    /// `demoSuspended` says whether a demo is running. It is a parameter rather than a read of
    /// `UserDefaults.standard` because everything else here is injected: a test that builds a
    /// service of its own must not have the app's own defaults decide whether it works. The
    /// app's own service passes the demo's real state.
    init(library: LibraryStore, playbackPositions: PlaybackPositionStore, defaults: UserDefaults, fileURL: URL,
         cloudKitAvailable: @escaping () -> Bool, demoSuspended: Bool = DemoMode.isRunning) {
        self.library = library
        self.playbackPositions = playbackPositions
        self.defaults = defaults
        self.fileURL = fileURL
        self.cloudKitAvailable = cloudKitAvailable
        isSuspended = demoSuspended
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if let data = try? Data(contentsOf: fileURL) {
            do {
                cache = try JSONDecoder().decode(Cache.self, from: data)
                if cache.schemaVersion != 1 {
                    cacheIsWritable = false
                    isEnabled = false
                    statusMessage = String(localized: "Update the app to read this iCloud sync data.")
                }
            } catch {
                // Preserve the damaged file for recovery. The library has its own durable
                // versions, so it can safely recreate the upload queue with a fresh engine.
                let recovery = fileURL.appendingPathExtension("recovery-\(UUID().uuidString)")
                try? FileManager.default.copyItem(at: fileURL, to: recovery)
                isEnabled = false
                defaults.set(false, forKey: Self.enabledKey)
                library.prepareForNewCloudAccount()
                playbackPositions.prepareForNewCloudAccount()
                statusMessage = String(localized: "The iCloud sync cache couldn't be read. Turn sync on to merge your local library again.")
            }
        }
        lastSyncDate = cache.lastSyncDate
        for key in Self.preferenceKeys { preferenceValues[key] = defaults.string(forKey: key) }
        library.onSyncChange = { [weak self] changes in self?.recordLocalChanges(changes) }
        playbackPositions.onSyncChange = { [weak self] changes in self?.recordLocalChanges(changes) }
        // Both can be posted from any thread — CloudKit's from a queue of its own — and the
        // closures below belong to the main actor, which Swift 6 checks when they run.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.capturePreferences() }
            }.store(in: &observations)
        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.checkAccount() }
            }.store(in: &observations)
        reconcileLocalEntries()
        if cacheIsWritable, statusMessage == Self.waitingMessage {
            if !cloudKitAvailable() {
                statusMessage = Self.unavailableMessage
            } else if !isEnabled {
                statusMessage = String(localized: "iCloud sync is off on this device.")
            }
        }
        if isSuspended { statusMessage = Self.pausedMessage }
    }

    /// Set while a demo runs. Its library is not this device's: none of it may reach iCloud, and
    /// nothing from iCloud may land in it. The on/off choice in Settings is left as it was.
    private(set) var isSuspended: Bool

    func suspendForDemo() {
        guard !isSuspended else { return }
        isSuspended = true
        let previous = engine
        engine = nil // Late delegate callbacks cannot mutate the demo's stores.
        activeOperations = 0
        isSyncing = false
        statusMessage = Self.pausedMessage
        Task { await previous?.cancelOperations() }
    }

    func resumeAfterDemo() {
        guard isSuspended else { return }
        isSuspended = false
        statusMessage = !cloudKitAvailable() ? Self.unavailableMessage
            : isEnabled ? Self.waitingMessage : String(localized: "iCloud sync is off on this device.")
        if isEnabled { Task { await start() } }
    }

    private static var pausedMessage: String {
        String(localized: "iCloud sync is paused during the demo. Your library is kept as it was.")
    }

    func setEnabled(_ enabled: Bool) {
        guard cacheIsWritable else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        generation += 1
        if enabled {
            reconcileLocalEntries()
            Task { await start() }
        } else {
            let previous = engine
            engine = nil // Late delegate callbacks cannot mutate the local stores.
            activeOperations = 0
            isSyncing = false
            statusMessage = String(localized: "iCloud sync is off on this device.")
            Task { await previous?.cancelOperations() }
        }
    }

    /// Called at launch and whenever the app becomes active. It also recovers after sign-in or
    /// a temporary account/network failure; CKSyncEngine handles automatic background retries.
    func start() async {
        guard !isSuspended, isEnabled, cacheIsWritable, engine == nil, !starting else { return }
        guard cloudKitAvailable() else {
            statusMessage = Self.unavailableMessage
            return
        }
        starting = true
        let revision = generation
        defer {
            starting = false
            if revision != generation, isEnabled { Task { await start() } }
        }
        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            guard try await container.accountStatus() == .available else {
                guard revision == generation else { return }
                statusMessage = String(localized: "Sign in to iCloud in system settings to sync this library.")
                return
            }
            let accountID = try await container.userRecordID().recordName
            guard revision == generation, isEnabled else { return }
            if let previous = cache.accountID, previous != accountID {
                accountChanged(to: accountID)
                return
            }
            cache.accountID = accountID
            reconcileLocalEntries()
            var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                            stateSerialization: cache.engineState,
                                                            delegate: self)
            configuration.automaticallySync = true
            let newEngine = CKSyncEngine(configuration)
            engine = newEngine
            newEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            queueDirtyEntries(on: newEngine)
            persist()
            statusMessage = String(localized: "Waiting for iCloud changes.")
        } catch {
            guard revision == generation else { return }
            show(error)
        }
    }

    func syncNow() async {
        await start()
        guard isEnabled, let current = engine else { return }
        let revision = generation
        do {
            // Fetch before sending a restored library, so server tombstones can defeat legacy
            // items. Server record conflicts apply the same deterministic version comparison.
            try await current.fetchChanges()
            guard revision == generation, engine === current else { return }
            queueDirtyEntries(on: current)
            try await current.sendChanges()
        } catch {
            guard revision == generation, engine === current else { return }
            show(error)
        }
    }

    /// Reset only this device. Clearing the outbox first prevents local erasure becoming a
    /// cloud deletion when sync is subsequently enabled again.
    func resetForDevice() async {
        resettingDevice = true
        setEnabled(false)
        cache = Cache()
        lastSyncDate = nil
        if cacheIsWritable { try? FileManager.default.removeItem(at: fileURL) }
    }

    func finishDeviceReset() {
        for key in Self.preferenceKeys { preferenceValues[key] = defaults.string(forKey: key) }
        resettingDevice = false
    }

    private func recordLocalChanges(_ changes: [CloudSyncEntry]) {
        guard cacheIsWritable, !resettingDevice, !isSuspended else { return }
        for entry in changes {
            guard cache.entries[entry.key].map({ entry.isNewer(than: $0) }) ?? true else { continue }
            cache.entries[entry.key] = entry
            cache.dirty.insert(entry.key)
        }
        persist()
        if isEnabled, let engine { queueDirtyEntries(on: engine) }
    }

    private func reconcileLocalEntries() {
        recordLocalChanges(Array(library.syncEntries.values))
        playbackPositions.flush()
        recordLocalChanges(Array(playbackPositions.syncEntries.values))
        // Initial preference migration only publishes explicit choices. In particular, the
        // Mac and phone have different defaults, which must not compete on a fresh install.
        for key in Self.preferenceKeys {
            let value = defaults.string(forKey: key)
            guard value.map({ Self.validPreference($0, key: key) }) ?? true else { continue }
            let id = "preference.\(key)"
            if let previous = cache.entries[id] {
                // AppStorage may have written just before a crash, without delivering its
                // notification. The durable default must still become a pending local edit.
                guard previous.value != value else { continue }
                recordLocalChanges([CloudSyncEntry(key: id,
                    modifiedAt: max(Date(), previous.modifiedAt.addingTimeInterval(0.001)),
                    changeID: UUID().uuidString, value: value)])
            } else if let value {
                // The first time this device publishes a preference. It carries no date of its
                // own on purpose: it is only a default until the user changes it, and a default
                // must never beat a real choice made on another device. Two devices publishing
                // one at the same moment do tie on the date, so the change ID orders them —
                // and it has to be a different one on each device, or the tie is not broken at
                // all and the two keep whatever they happened to fetch last.
                recordLocalChanges([CloudSyncEntry(key: id, modifiedAt: .distantPast,
                                                   changeID: UUID().uuidString, value: value)])
            }
        }
    }

    private func capturePreferences() {
        guard !applyingPreferences, cacheIsWritable, !resettingDevice, !isSuspended else { return }
        for key in Self.preferenceKeys {
            let value = defaults.string(forKey: key)
            guard value != preferenceValues[key] else { continue }
            preferenceValues[key] = value
            guard value == nil || Self.validPreference(value!, key: key) else { continue }
            let id = "preference.\(key)"
            let previousDate = cache.entries[id]?.modifiedAt ?? .distantPast
            recordLocalChanges([CloudSyncEntry(key: id, modifiedAt: max(Date(), previousDate.addingTimeInterval(0.001)),
                                               changeID: UUID().uuidString, video: nil, value: value)])
        }
    }

    private func applyToStores(_ entries: [CloudSyncEntry]) {
        library.mergeSyncEntries(entries)
        playbackPositions.mergeSyncEntries(entries)
        applyingPreferences = true
        defer { applyingPreferences = false }
        for entry in entries where entry.key.hasPrefix("preference.") {
            let key = String(entry.key.dropFirst("preference.".count))
            guard Self.preferenceKeys.contains(key),
                  entry.value.map({ Self.validPreference($0, key: key) }) ?? true else { continue }
            // Update the comparison cache before UserDefaults broadcasts its change.
            preferenceValues[key] = entry.value
            if let value = entry.value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    private static func validPreference(_ value: String, key: String) -> Bool {
        switch key {
        case MiniPlayerStyle.storageKey: return MiniPlayerStyle(rawValue: value) != nil
        case FloatingMiniPlayerSize.storageKey: return FloatingMiniPlayerSize(rawValue: value) != nil
        default: return false
        }
    }

    private func queueDirtyEntries(on engine: CKSyncEngine) {
        engine.state.add(pendingRecordZoneChanges: cache.dirty.sorted().map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID))
        })
    }

    private func persist() {
        guard cacheIsWritable else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: fileURL, options: .atomic)
        } catch {
            operationFailed = true
            statusMessage = String(localized: "Couldn't save the iCloud upload queue. Your library is still stored locally.")
        }
    }

    private func show(_ error: Error) {
        operationFailed = true
        if let cloudError = error as? CKError {
            switch cloudError.code {
            case .networkFailure, .networkUnavailable:
                statusMessage = String(localized: "Offline. Changes will sync when the connection returns.")
            case .notAuthenticated:
                statusMessage = String(localized: "Sign in to iCloud in system settings to sync this library.")
            case .quotaExceeded:
                statusMessage = String(localized: "iCloud storage is full. Free some space to continue syncing.")
            default:
                statusMessage = String(localized: "iCloud sync couldn't finish: \(cloudError.localizedDescription)")
            }
        } else { statusMessage = String(localized: "iCloud sync couldn't finish: \(error.localizedDescription)") }
    }

    private func checkAccount() async {
        guard isEnabled, cloudKitAvailable() else { return }
        let revision = generation
        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            let status = try await container.accountStatus()
            guard revision == generation, isEnabled else { return }
            guard status == .available else {
                // Preserve data and the original identity, but require an explicit opt-in
                // after signing out. Never copy an old account's library automatically.
                setEnabled(false)
                statusMessage = String(localized: "iCloud signed out. Your library is kept on this device.")
                return
            }
            let account = try await container.userRecordID().recordName
            guard revision == generation, isEnabled else { return }
            if let previous = cache.accountID, previous != account { accountChanged(to: account) }
            else { await start() }
        } catch {
            guard revision == generation, isEnabled else { return }
            show(error)
        }
    }

    private func accountChanged(to accountID: String?) {
        setEnabled(false)
        library.prepareForNewCloudAccount()
        playbackPositions.prepareForNewCloudAccount()
        cache = Cache(accountID: accountID)
        lastSyncDate = nil
        persist()
        statusMessage = String(localized: "iCloud account changed. Turn sync on to merge this device's library with the new account.")
    }

    private static func hasCloudKitEntitlement() -> Bool {
        // Unit tests/previews use an unsigned host and must never initialize CKContainer.
        if NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return false }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
        else { return false }
        return services.contains("CloudKit")
        #elseif targetEnvironment(simulator)
        // Xcode signs the entitlements straight into a simulator build; there is no profile to read.
        return true
        #else
        // A build installed from Xcode carries its provisioning profile, which lists what it may
        // use — and a free personal team can't provision iCloud. Creating a CloudKit container
        // without it stops the app at launch, so sync stays off instead. App Store and TestFlight
        // builds carry no profile, and are always provisioned.
        guard let entitlements = provisionedEntitlements() else { return true }
        return (entitlements["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") ?? false
        #endif
    }

    #if os(iOS) && !targetEnvironment(simulator)
    /// The entitlements in the app's `embedded.mobileprovision`: a signed envelope around a
    /// property list, which is read out from between its markers.
    private static func provisionedEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return profile["Entitlements"] as? [String: Any] ?? [:]
    }
    #endif
}

extension ICloudSyncService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard isEnabled, engine === syncEngine else { return }
        switch event {
        case .stateUpdate(let update):
            cache.engineState = update.stateSerialization
            persist()
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user):
                if let previous = cache.accountID, previous != user.recordName { accountChanged(to: user.recordName) }
            case .signOut:
                setEnabled(false)
                statusMessage = String(localized: "iCloud signed out. Your library is kept on this device.")
            case .switchAccounts(_, let current): accountChanged(to: current.recordName)
            @unknown default: setEnabled(false)
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications { mergeServerRecord(modification.record) }
            // Normal removals are saved tombstones. Physical deletions mean data was removed
            // outside the app; drop the cached copy and prevent a stale pending save resurrecting it.
            for deletion in changes.deletions where deletion.recordID.zoneID == Self.zoneID {
                let key = deletion.recordID.recordName
                if CloudPlaybackPosition.videoID(in: key) != nil { playbackPositions.flush() }
                guard let old = cache.entries[key] else { continue }
                let removed = CloudSyncEntry(key: key, modifiedAt: max(Date(), old.modifiedAt.addingTimeInterval(0.001)),
                                             changeID: UUID().uuidString, video: nil, value: nil)
                cache.entries[key] = removed
                cache.systemFields[key] = nil
                cache.dirty.remove(key)
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
                applyToStores([removed])
            }
            persist()
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                // A deleted cloud zone must never be silently recreated from an old device.
                accountChanged(to: cache.accountID)
                statusMessage = String(localized: "The iCloud library was removed. Turn sync on to upload your local library again.")
            }
        case .sentRecordZoneChanges(let changes):
            for record in changes.savedRecords {
                let key = record.recordID.recordName
                cache.systemFields[key] = Self.systemFields(of: record)
                if let sent = Self.entry(from: record), cache.entries[key] == sent { cache.dirty.remove(key) }
                else if cache.entries[key] != nil {
                    cache.dirty.insert(key)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                }
            }
            for failed in changes.failedRecordSaves {
                let key = failed.record.recordID.recordName
                switch failed.error.code {
                case .serverRecordChanged:
                    if let server = failed.error.serverRecord { mergeServerRecord(server) }
                    else { show(failed.error) }
                case .zoneNotFound:
                    cache.systemFields[key] = nil
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                case .unknownItem:
                    cache.systemFields[key] = nil
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                default: show(failed.error) // CKSyncEngine retries transient failures.
                }
            }
            persist()
        case .sentDatabaseChanges(let changes):
            for failure in changes.failedZoneSaves { show(failure.error) }
        case .willFetchChanges, .willSendChanges:
            if activeOperations == 0 { operationFailed = false }
            activeOperations += 1
            isSyncing = true
            statusMessage = String(localized: "Syncing with iCloud…")
        case .didFetchRecordZoneChanges(let result):
            if let error = result.error { show(error) }
        case .didFetchChanges, .didSendChanges:
            activeOperations = max(0, activeOperations - 1)
            isSyncing = activeOperations > 0
            if !isSyncing, !operationFailed {
                if cache.dirty.isEmpty {
                    lastSyncDate = Date()
                    cache.lastSyncDate = lastSyncDate
                    statusMessage = String(localized: "Up to date with iCloud.")
                } else { statusMessage = String(localized: "Changes are saved locally and waiting for iCloud.") }
                persist()
            }
        default: break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                  syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard isEnabled, engine === syncEngine else { return nil }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }.prefix(100)
        var records: [CKRecord] = []
        for change in changes {
            guard case .saveRecord(let id) = change,
                  let entry = cache.entries[id.recordName] else {
                syncEngine.state.remove(pendingRecordZoneChanges: [change])
                continue
            }
            do { records.append(try Self.record(for: entry, systemFields: cache.systemFields[entry.key])) }
            catch { show(error); return nil }
        }
        return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
    }

    /// Also testable with CloudKit records without creating a live sync engine.
    func mergeServerRecord(_ record: CKRecord) {
        guard isEnabled, cacheIsWritable, !resettingDevice, record.recordID.zoneID == Self.zoneID else { return }
        guard let incoming = Self.entry(from: record) else {
            operationFailed = true
            statusMessage = String(localized: "Update the app to read an unsupported iCloud record.")
            return
        }
        let key = incoming.key
        // Include playback since the last five-second checkpoint in conflict resolution.
        // A fetched record must not displace a more recent, still-unflushed local seek.
        if CloudPlaybackPosition.videoID(in: key) != nil { playbackPositions.flush() }
        cache.systemFields[key] = Self.systemFields(of: record)
        if let local = cache.entries[key], local.isNewer(than: incoming) {
            cache.dirty.insert(key)
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        } else {
            cache.entries[key] = incoming
            cache.dirty.remove(key)
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            applyToStores([incoming])
        }
        persist()
    }

    static func entry(from record: CKRecord) -> CloudSyncEntry? {
        guard record.recordType == recordType, record["schemaVersion"] as? Int64 == 1,
              let data = record["payload"] as? Data,
              let entry = try? JSONDecoder().decode(CloudSyncEntry.self, from: data),
              entry.key == record.recordID.recordName else { return nil }
        if let list = CloudLibraryList(key: entry.key) {
            guard entry.value == nil, entry.position == nil,
                  entry.video.map({ list.key(for: $0.id) == entry.key }) ?? true else { return nil }
        } else if CloudPlaybackPosition.videoID(in: entry.key) != nil {
            guard CloudPlaybackPosition.isValid(entry) else { return nil }
        } else {
            let key = String(entry.key.dropFirst("preference.".count))
            guard entry.key.hasPrefix("preference."), preferenceKeys.contains(key), entry.video == nil, entry.position == nil,
                  entry.value.map({ validPreference($0, key: key) }) ?? true else { return nil }
        }
        return entry
    }

    static func record(for entry: CloudSyncEntry, systemFields: Data? = nil) throws -> CKRecord {
        let id = CKRecord.ID(recordName: entry.key, zoneID: zoneID)
        var record: CKRecord?
        if let systemFields, let decoder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            decoder.requiresSecureCoding = true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            record = CKRecord(coder: decoder)
            decoder.finishDecoding()
            if record?.recordID != id || record?.recordType != recordType { record = nil }
        }
        let result = record ?? CKRecord(recordType: recordType, recordID: id)
        result["schemaVersion"] = Int64(1)
        result["payload"] = try JSONEncoder().encode(entry)
        return result
    }

    static func systemFields(of record: CKRecord) -> Data {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        encoder.finishEncoding()
        return encoder.encodedData
    }
}
