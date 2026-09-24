import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

private struct ApplicationFilterCondition: Sendable {
    let field: String
    let value: String
}

private struct ApplicationOrder: Sendable {
    let field: String
    let descending: Bool
}

extension ExactMacService {
    func getApplicationBundle(
        request: ServerRequest<Exactmac_V1_GetApplicationBundleRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ApplicationBundle> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "GetApplicationBundleRequest")
        let fullView = try Self.validateApplicationView(req.view)
        let bundle = try await resolveApplicationBundle(name: req.name)
        return ServerResponse(message: Self.makeApplicationBundle(bundle, fullView: fullView))
    }

    func listApplicationBundles(
        request: ServerRequest<Exactmac_V1_ListApplicationBundlesRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListApplicationBundlesResponse> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "ListApplicationBundlesRequest")
        let fullView = try Self.validateApplicationView(req.view)
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let skip = try RequestNumericValidation.skip(req.skip)
        let order = try Self.parseApplicationOrder(
            req.orderBy,
            defaultField: "name",
            allowedFields: ["name", "display_name", "bundle_id", "bundle_url"],
        )
        let filters = try Self.parseApplicationFilter(
            req.filter,
            allowedFields: ["display_name", "bundle_id"],
        )
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListApplicationBundles",
            parameters: [
                ("order_by", req.orderBy),
                ("filter", req.filter),
                ("view", String(req.view.rawValue)),
            ],
        )
        let cursor = try ParsingHelpers.pageCursor(
            token: req.pageToken,
            skip: skip,
            queryBinding: queryBinding,
        )

        let discovered = await applicationCatalogProvider.applicationBundles()
        let bundles = Self.validApplicationBundles(discovered)
            .filter { Self.applicationBundle($0, matches: filters) }
            .sorted { Self.applicationBundle($0, precedes: $1, order: order) }
        let range = try ParsingHelpers.pageRange(
            cursor: cursor,
            pageSize: pageSize,
            totalCount: bundles.count,
        )
        let page = bundles[range].map {
            Self.makeApplicationBundle($0, fullView: fullView)
        }
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: bundles.count,
            queryBinding: queryBinding,
        )
        return ServerResponse(message: Exactmac_V1_ListApplicationBundlesResponse.with {
            $0.applicationBundles = Array(page)
            $0.nextPageToken = nextPageToken
        })
    }

    func openApplication(
        request: ServerRequest<Exactmac_V1_OpenApplicationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_OpenApplicationResponse> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "OpenApplicationRequest")
        _ = try ParsingHelpers.parseApplicationBundleName(req.name)
        let mode: ExactMac.AppLaunchMode = switch req.mode {
        case .unspecified, .launchOrActivate:
            .launchOrActivate
        case .forceNewInstance:
            .forceNewInstance
        case .UNRECOGNIZED:
            throw RPCErrorHelpers.validationError(
                message: "mode is not recognized",
                reason: "INVALID_ENUM_VALUE",
                field: "mode",
                value: String(req.mode.rawValue),
            )
        }

        Self.logger.info(
            "openApplication called for exact bundle resource \(req.name, privacy: .private(mask: .hash)) background=\(req.background, privacy: .public) mode=\(mode.rawValue, privacy: .public)",
        )
        return try await withCancellationShieldedApplicationMutation {
            try await self.openApplicationAdmitted(
                bundleName: req.name,
                background: req.background,
                mode: mode,
            )
        }
    }

    private func openApplicationAdmitted(
        bundleName: String,
        background: Bool,
        mode: ExactMac.AppLaunchMode,
    ) async throws -> ServerResponse<Exactmac_V1_OpenApplicationResponse> {
        let catalog = applicationCatalogProvider
        let coordinator = automationCoordinator
        let stateStore = stateStore
        let system = system

        let message = try await Task.detached(priority: .userInitiated) {
            let bundle = try await Self.resolveApplicationBundle(
                name: bundleName,
                catalog: catalog,
            )
            let opened = try await coordinator.handleOpenApplication(
                applicationURL: bundle.bundleURL,
                background: background,
                mode: mode,
            )
            guard let identity = await Self.captureApplicationProcessIdentity(
                system: system,
                pid: opened.pid,
                timeout: .seconds(1),
            ) else {
                throw RPCError(
                    code: .unavailable,
                    message: "Unable to capture stable process identity for PID \(opened.pid)",
                )
            }

            let runningSnapshot = await catalog.runningApplications()
            let observed = runningSnapshot.first {
                $0.pid == opened.pid &&
                    ($0.bundleURL.map(canonicalApplicationBundleURL) == bundle.bundleURL)
            } ?? RunningApplicationInfo(
                pid: opened.pid,
                displayName: opened.appName,
                bundleID: bundle.bundleID,
                bundleURL: bundle.bundleURL,
                bundleIdentity: bundle.identity,
                launchDate: nil,
                active: opened.active,
            )
            let application = Self.makeApplication(observed, identity: identity)
            await stateStore.addTarget(application, processIdentity: identity)

            return Exactmac_V1_OpenApplicationResponse.with {
                $0.application = application
                $0.disposition = switch opened.actionTaken {
                case .launchedNew:
                    .launchedNew
                case .activatedExisting:
                    .activatedExisting
                case .alreadyActive:
                    .alreadyActive
                case .reusedExisting:
                    .reusedExisting
                }
            }
        }.value
        return ServerResponse(message: message)
    }

    func getApplication(
        request: ServerRequest<Exactmac_V1_GetApplicationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Application> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "GetApplicationRequest")
        _ = try ParsingHelpers.parseOpaqueApplicationName(req.name)
        let fullView = try Self.validateApplicationView(req.view)
        await refreshRunningApplicationState()
        guard let application = await stateStore.getTarget(name: req.name),
              let identity = await stateStore.getApplicationProcessIdentity(name: req.name),
              system.isApplicationProcessRunning(identity)
        else {
            throw RPCError(code: .notFound, message: "Application not found")
        }
        return ServerResponse(message: Self.applyApplicationView(application, fullView: fullView))
    }

    func listApplications(
        request: ServerRequest<Exactmac_V1_ListApplicationsRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListApplicationsResponse> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "ListApplicationsRequest")
        let fullView = try Self.validateApplicationView(req.view)
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let skip = try RequestNumericValidation.skip(req.skip)
        let order = try Self.parseApplicationOrder(
            req.orderBy,
            defaultField: "name",
            allowedFields: ["name", "pid", "display_name", "bundle_id", "active"],
        )
        let filters = try Self.parseApplicationFilter(
            req.filter,
            allowedFields: ["display_name", "bundle_id"],
        )
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListApplications",
            parameters: [
                ("order_by", req.orderBy),
                ("filter", req.filter),
                ("view", String(req.view.rawValue)),
            ],
        )
        let cursor = try ParsingHelpers.pageCursor(
            token: req.pageToken,
            skip: skip,
            queryBinding: queryBinding,
        )

        await refreshRunningApplicationState()
        let applications = await stateStore.listTargets()
        let ordered = applications
            .filter { Self.application($0, matches: filters) }
            .sorted { Self.application($0, precedes: $1, order: order) }
        let range = try ParsingHelpers.pageRange(
            cursor: cursor,
            pageSize: pageSize,
            totalCount: ordered.count,
        )
        let page = ordered[range].map {
            Self.applyApplicationView($0, fullView: fullView)
        }
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: ordered.count,
            queryBinding: queryBinding,
        )
        return ServerResponse(message: Exactmac_V1_ListApplicationsResponse.with {
            $0.applications = Array(page)
            $0.nextPageToken = nextPageToken
        })
    }

    func activateApplication(
        request: ServerRequest<Exactmac_V1_ActivateApplicationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ActivateApplicationResponse> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "ActivateApplicationRequest")
        _ = try ParsingHelpers.parseOpaqueApplicationName(req.name)
        return try await withCancellationShieldedApplicationMutation {
            try await self.activateApplicationAdmitted(name: req.name)
        }
    }

    private func activateApplicationAdmitted(
        name: String,
    ) async throws -> ServerResponse<Exactmac_V1_ActivateApplicationResponse> {
        let catalog = applicationCatalogProvider
        let stateStore = stateStore
        let system = system
        let message = try await Task.detached(priority: .userInitiated) {
            await Self.refreshRunningApplicationState(
                catalog: catalog,
                system: system,
                stateStore: stateStore,
            )
            guard let before = await stateStore.getTarget(name: name),
                  let identity = await stateStore.getApplicationProcessIdentity(name: name),
                  system.isApplicationProcessRunning(identity)
            else {
                throw RPCError(code: .notFound, message: "Application not found or process identity is stale")
            }
            if before.active {
                return Exactmac_V1_ActivateApplicationResponse.with {
                    $0.application = before
                    $0.disposition = .alreadyActive
                }
            }

            let accepted = system.requestApplicationActivation(identity)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while true {
                await Self.refreshRunningApplicationState(
                    catalog: catalog,
                    system: system,
                    stateStore: stateStore,
                )
                guard let current = await stateStore.getTarget(name: name),
                      let currentIdentity = await stateStore.getApplicationProcessIdentity(name: name),
                      currentIdentity == identity,
                      system.isApplicationProcessRunning(identity)
                else {
                    throw RPCError(code: .notFound, message: "Application process identity became stale during activation")
                }
                if current.active {
                    return Exactmac_V1_ActivateApplicationResponse.with {
                        $0.application = current
                        $0.disposition = .activated
                    }
                }
                if !accepted {
                    throw RPCError(code: .failedPrecondition, message: "Exact application rejected activation")
                }
                guard clock.now < deadline else {
                    throw RPCError(code: .deadlineExceeded, message: "Timed out waiting for exact application activation")
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }.value
        return ServerResponse(message: message)
    }

    func closeApplication(
        request: ServerRequest<Exactmac_V1_CloseApplicationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_CloseApplicationResponse> {
        let req = request.message
        try Self.rejectUnknownFields(req.unknownFields, requestName: "CloseApplicationRequest")
        _ = try ParsingHelpers.parseOpaqueApplicationName(req.name)
        return try await withApplicationMutation {
            try await self.closeApplicationAdmitted(name: req.name, force: req.force)
        }
    }

    private func closeApplicationAdmitted(
        name: String,
        force: Bool,
    ) async throws -> ServerResponse<Exactmac_V1_CloseApplicationResponse> {
        if await stateStore.getTarget(name: name) == nil {
            await refreshRunningApplicationState()
        }
        guard let application = await stateStore.getTarget(name: name),
              let identity = await stateStore.getApplicationProcessIdentity(name: name)
        else {
            throw RPCError(code: .notFound, message: "Application not found")
        }

        var disposition = Exactmac_V1_ApplicationCloseDisposition.alreadyExited
        if system.isApplicationProcessRunning(identity) {
            let gracefulAccepted = system.requestApplicationTermination(identity, force: false)
            if await waitForApplicationExit(identity, timeout: applicationTerminationGracePeriod) {
                disposition = .graceful
            } else {
                guard force else {
                    let message = gracefulAccepted
                        ? "Owned application remained alive after the graceful close request"
                        : "Owned application rejected the graceful close request"
                    throw RPCError(
                        code: gracefulAccepted ? .deadlineExceeded : .failedPrecondition,
                        message: message,
                    )
                }
                guard system.isApplicationProcessRunning(identity) else {
                    return await finishApplicationClose(
                        application: application,
                        disposition: .graceful,
                    )
                }
                let forceAccepted = system.requestApplicationTermination(identity, force: true)
                if !forceAccepted, system.isApplicationProcessRunning(identity) {
                    throw RPCError(code: .failedPrecondition, message: "Owned application rejected force termination")
                }
                guard await waitForApplicationExit(
                    identity,
                    timeout: applicationTerminationForcePeriod,
                ) else {
                    throw RPCError(code: .deadlineExceeded, message: "Owned application remained alive after force termination")
                }
                disposition = .forced
            }
        } else if system.isProcessRunning(pid: identity.pid) {
            throw RPCError(code: .notFound, message: "Application process identity is stale")
        }

        return await finishApplicationClose(
            application: application,
            disposition: disposition,
        )
    }

    private func waitForApplicationExit(
        _ identity: ApplicationProcessIdentity,
        timeout: Duration,
    ) async -> Bool {
        let system = system
        return await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while system.isApplicationProcessRunning(identity) {
                if clock.now >= deadline {
                    return false
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return true
        }.value
    }

    private static func captureApplicationProcessIdentity(
        system: SystemOperations,
        pid: pid_t,
        timeout: Duration,
    ) async -> ApplicationProcessIdentity? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let identity = system.applicationProcessIdentity(pid: pid) {
                return identity
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        return nil
    }

    private func finishApplicationClose(
        application: Exactmac_V1_Application,
        disposition: Exactmac_V1_ApplicationCloseDisposition,
    ) async -> ServerResponse<Exactmac_V1_CloseApplicationResponse> {
        let pid = application.pid
        // PID-indexed child caches cannot safely be touched after reuse. Their
        // migration to opaque parents remains in this active campaign.
        if !system.isProcessRunning(pid: pid) {
            let cleared = await elementRegistry.clearElements(forPid: pid)
            if cleared > 0 {
                Self.logger.info("Cleared \(cleared, privacy: .public) cached elements for exited PID \(pid, privacy: .public)")
            }
            await windowRegistry.invalidate(forPID: pid)
        }
        _ = await stateStore.removeTarget(name: application.name)
        return ServerResponse(message: Exactmac_V1_CloseApplicationResponse.with {
            $0.application = application
            $0.disposition = disposition
        })
    }

    func refreshRunningApplicationState() async {
        await Self.refreshRunningApplicationState(
            catalog: applicationCatalogProvider,
            system: system,
            stateStore: stateStore,
        )
    }

    private static func refreshRunningApplicationState(
        catalog: any ApplicationCatalogProvider,
        system: SystemOperations,
        stateStore: AppStateStore,
    ) async {
        let discovered = await catalog.runningApplications()
        var seenPIDs = Set<pid_t>()
        var targets: [(application: Exactmac_V1_Application, identity: ApplicationProcessIdentity)] = []
        for info in discovered where info.pid > 0 && seenPIDs.insert(info.pid).inserted {
            guard let identity = system.applicationProcessIdentity(pid: info.pid),
                  identity.pid == info.pid
            else {
                continue
            }
            targets.append((Self.makeApplication(info, identity: identity), identity))
        }
        await stateStore.reconcileTargets(targets) { identity in
            system.isApplicationProcessRunning(identity)
        }
    }

    private func resolveApplicationBundle(name: String) async throws -> ApplicationBundleInfo {
        try await Self.resolveApplicationBundle(
            name: name,
            catalog: applicationCatalogProvider,
        )
    }

    private static func resolveApplicationBundle(
        name: String,
        catalog: any ApplicationCatalogProvider,
    ) async throws -> ApplicationBundleInfo {
        let resource = try ParsingHelpers.parseApplicationBundleName(name)
        let bundles = await validApplicationBundles(catalog.applicationBundles())
        guard let bundle = bundles.first(where: { $0.identity == resource.resourceID }) else {
            throw RPCError(code: .notFound, message: "Application bundle not found")
        }
        return bundle
    }

    private static func validApplicationBundles(
        _ bundles: [ApplicationBundleInfo],
    ) -> [ApplicationBundleInfo] {
        var seen = Set<String>()
        return bundles.filter { bundle in
            bundle.identity == applicationBundleIdentity(for: bundle.bundleURL) &&
                seen.insert(bundle.identity).inserted
        }
    }

    private static func makeApplicationBundle(
        _ bundle: ApplicationBundleInfo,
        fullView: Bool,
    ) -> Exactmac_V1_ApplicationBundle {
        Exactmac_V1_ApplicationBundle.with {
            $0.name = "applicationBundles/\(bundle.identity)"
            $0.displayName = bundle.displayName
            $0.bundleID = bundle.bundleID ?? ""
            if fullView {
                $0.bundleURL = bundle.bundleURL.absoluteString
                $0.version = bundle.version ?? ""
            }
        }
    }

    private static func makeApplication(
        _ running: RunningApplicationInfo,
        identity: ApplicationProcessIdentity,
    ) -> Exactmac_V1_Application {
        Exactmac_V1_Application.with {
            $0.name = applicationResourceName(for: identity)
            $0.pid = Int32(running.pid)
            $0.displayName = running.displayName
            if let bundleIdentity = running.bundleIdentity {
                $0.applicationBundle = "applicationBundles/\(bundleIdentity)"
            }
            $0.bundleID = running.bundleID ?? identity.bundleIdentifier ?? ""
            $0.active = running.active
            if identity.startTimeSeconds <= UInt64(Int64.max),
               identity.startTimeMicroseconds < 1_000_000
            {
                $0.processStartTime = SwiftProtobuf.Google_Protobuf_Timestamp.with {
                    $0.seconds = Int64(identity.startTimeSeconds)
                    $0.nanos = Int32(identity.startTimeMicroseconds * 1000)
                }
            }
        }
    }

    private static func applyApplicationView(
        _ application: Exactmac_V1_Application,
        fullView: Bool,
    ) -> Exactmac_V1_Application {
        guard !fullView else { return application }
        var basic = application
        basic.clearProcessStartTime()
        return basic
    }

    private static func rejectUnknownFields(
        _ unknownFields: SwiftProtobuf.UnknownStorage,
        requestName: String,
    ) throws {
        guard unknownFields.data.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "\(requestName) contains unknown fields",
                reason: "UNKNOWN_FIELD",
                field: "request",
            )
        }
    }

    private static func validateApplicationView(
        _ view: Exactmac_V1_ApplicationView,
    ) throws -> Bool {
        switch view {
        case .unspecified, .basic:
            false
        case .full:
            true
        case .UNRECOGNIZED:
            throw RPCErrorHelpers.validationError(
                message: "view is not recognized",
                reason: "INVALID_ENUM_VALUE",
                field: "view",
                value: String(view.rawValue),
            )
        }
    }

    private static func parseApplicationOrder(
        _ rawOrder: String,
        defaultField: String,
        allowedFields: Set<String>,
    ) throws -> ApplicationOrder {
        let trimmed = rawOrder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ApplicationOrder(field: defaultField, descending: false)
        }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "desc"),
              allowedFields.contains(parts[0])
        else {
            throw RPCErrorHelpers.validationError(
                message: "order_by contains an unsupported field or direction",
                reason: "INVALID_ORDER_BY",
                field: "order_by",
                value: rawOrder,
            )
        }
        return ApplicationOrder(field: parts[0], descending: parts.count == 2)
    }

    private static func parseApplicationFilter(
        _ rawFilter: String,
        allowedFields: Set<String>,
    ) throws -> [ApplicationFilterCondition] {
        let characters = Array(rawFilter)
        var index = 0

        func isWhitespace(_ character: Character) -> Bool {
            character.isWhitespace
        }

        func skipWhitespace() {
            while index < characters.count, isWhitespace(characters[index]) {
                index += 1
            }
        }

        skipWhitespace()
        guard index < characters.count else { return [] }
        var conditions: [ApplicationFilterCondition] = []
        while index < characters.count {
            let fieldStart = index
            while index < characters.count,
                  characters[index].isLetter || characters[index] == "_"
            {
                index += 1
            }
            let field = String(characters[fieldStart ..< index]).lowercased()
            guard !field.isEmpty, allowedFields.contains(field) else {
                throw invalidApplicationFilter(rawFilter)
            }
            skipWhitespace()
            guard index < characters.count, characters[index] == "=" else {
                throw invalidApplicationFilter(rawFilter)
            }
            index += 1
            skipWhitespace()
            guard index < characters.count, characters[index] == "\"" else {
                throw invalidApplicationFilter(rawFilter)
            }
            index += 1
            var value = ""
            var closed = false
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" {
                    closed = true
                    break
                }
                if character == "\\" {
                    guard index < characters.count else {
                        throw invalidApplicationFilter(rawFilter)
                    }
                    let escaped = characters[index]
                    index += 1
                    switch escaped {
                    case "\"", "\\":
                        value.append(escaped)
                    case "n":
                        value.append("\n")
                    case "r":
                        value.append("\r")
                    case "t":
                        value.append("\t")
                    default:
                        throw invalidApplicationFilter(rawFilter)
                    }
                } else {
                    value.append(character)
                }
            }
            guard closed else { throw invalidApplicationFilter(rawFilter) }
            conditions.append(ApplicationFilterCondition(field: field, value: value))

            let separatorStart = index
            skipWhitespace()
            guard index < characters.count else { break }
            guard index > separatorStart, index + 3 <= characters.count,
                  String(characters[index ..< index + 3]).lowercased() == "and"
            else {
                throw invalidApplicationFilter(rawFilter)
            }
            index += 3
            guard index < characters.count, characters[index].isWhitespace else {
                throw invalidApplicationFilter(rawFilter)
            }
            skipWhitespace()
            guard index < characters.count else { throw invalidApplicationFilter(rawFilter) }
        }
        return conditions
    }

    private static func invalidApplicationFilter(_ rawFilter: String) -> RPCError {
        RPCErrorHelpers.validationError(
            message: "filter must contain supported quoted equality conditions joined by AND",
            reason: "INVALID_FILTER",
            field: "filter",
            value: rawFilter,
        )
    }

    private static func applicationBundle(
        _ bundle: ApplicationBundleInfo,
        matches filters: [ApplicationFilterCondition],
    ) -> Bool {
        filters.allSatisfy { condition in
            switch condition.field {
            case "display_name":
                bundle.displayName.localizedCaseInsensitiveCompare(condition.value) == .orderedSame
            case "bundle_id":
                bundle.bundleID == condition.value
            default:
                false
            }
        }
    }

    private static func application(
        _ application: Exactmac_V1_Application,
        matches filters: [ApplicationFilterCondition],
    ) -> Bool {
        filters.allSatisfy { condition in
            switch condition.field {
            case "display_name":
                application.displayName.localizedCaseInsensitiveCompare(condition.value) == .orderedSame
            case "bundle_id":
                application.bundleID == condition.value
            default:
                false
            }
        }
    }

    private static func applicationBundle(
        _ lhs: ApplicationBundleInfo,
        precedes rhs: ApplicationBundleInfo,
        order: ApplicationOrder,
    ) -> Bool {
        let comparison: ComparisonResult = switch order.field {
        case "display_name":
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        case "bundle_id":
            (lhs.bundleID ?? "").localizedCaseInsensitiveCompare(rhs.bundleID ?? "")
        case "bundle_url":
            lhs.bundleURL.absoluteString.compare(rhs.bundleURL.absoluteString)
        default:
            lhs.identity.compare(rhs.identity)
        }
        let resolved = comparison == .orderedSame
            ? lhs.identity.compare(rhs.identity)
            : comparison
        return order.descending ? resolved == .orderedDescending : resolved == .orderedAscending
    }

    private static func application(
        _ lhs: Exactmac_V1_Application,
        precedes rhs: Exactmac_V1_Application,
        order: ApplicationOrder,
    ) -> Bool {
        let comparison: ComparisonResult = switch order.field {
        case "pid":
            lhs.pid == rhs.pid ? .orderedSame : (lhs.pid < rhs.pid ? .orderedAscending : .orderedDescending)
        case "display_name":
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        case "bundle_id":
            lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
        case "active":
            lhs.active == rhs.active ? .orderedSame : (lhs.active ? .orderedDescending : .orderedAscending)
        default:
            lhs.name.compare(rhs.name)
        }
        let resolved = comparison == .orderedSame ? lhs.name.compare(rhs.name) : comparison
        return order.descending ? resolved == .orderedDescending : resolved == .orderedAscending
    }

    /// Retained internal helpers for non-RPC utility tests. Production List
    /// methods use the strict full-expression parser above.
    func applyApplicationFilter(
        _ applications: [Exactmac_V1_Application],
        filter: String,
    ) -> [Exactmac_V1_Application] {
        guard let value = extractQuotedValueForApp(from: filter, key: "name") else {
            return applications
        }
        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(value)
        }
    }

    func extractQuotedValueForApp(from filter: String, key: String) -> String? {
        let pattern = "^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"]*)\"\\s*$$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(filter.startIndex ..< filter.endIndex, in: filter)
        guard let match = regex.firstMatch(in: filter, range: range),
              let valueRange = Range(match.range(at: 1), in: filter)
        else {
            return nil
        }
        return String(filter[valueRange])
    }

    private func withApplicationMutation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result,
    ) async throws -> Result {
        do {
            return try await physicalDesktopMutationGate.withExclusiveOperation(operation)
        } catch PhysicalDesktopMutationError.queueFull {
            throw RPCError(code: .resourceExhausted, message: "Physical desktop mutation queue is full")
        } catch PhysicalDesktopMutationError.admissionClosed {
            throw RPCError(code: .unavailable, message: "Physical desktop mutation admission is closed")
        }
    }

    private func withCancellationShieldedApplicationMutation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result,
    ) async throws -> Result {
        let mutation = Task {
            try await withApplicationMutation(operation)
        }
        return try await withTaskCancellationHandler {
            try await withRPCCancellationHandler {
                try await mutation.value
            } onCancelRPC: {
                mutation.cancel()
            }
        } onCancel: {
            mutation.cancel()
        }
    }
}
