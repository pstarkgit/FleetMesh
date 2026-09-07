import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let fleetMeshInvitation = UTType(
        exportedAs: "dev.starkpat.fleetmesh.invitation",
        conformingTo: .json
    )
}

enum FleetEnrollmentTransition: Equatable, Sendable {
    case join
    case move(currentFleetID: String, destinationFleetID: String)
    case alreadyConnected
}

struct FleetEnrollmentInvitation: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultReporterProfileHint = "fleetmesh-reporter"

    let schemaVersion: Int
    let createdAt: Date
    let region: String
    let table: String
    let fleetID: String
    let reporterProfileHint: String
    let suggestedRole: DeviceRole

    init(
        region: String,
        table: String,
        fleetID: String,
        reporterProfileHint: String = Self.defaultReporterProfileHint,
        suggestedRole: DeviceRole = .workstation,
        createdAt: Date = Date()
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.region = region
        self.table = table
        self.fleetID = fleetID
        self.reporterProfileHint = reporterProfileHint
        self.suggestedRole = suggestedRole
        try validate()
    }

    static func make(from state: LocalDeviceState) throws -> FleetEnrollmentInvitation {
        guard state.effectiveStorageBackend == .dynamodb,
              let configuration = try state.dynamoDBConfiguration() else {
            throw FleetEnrollmentInvitationError.dynamoDBAuthorityRequired
        }
        return try FleetEnrollmentInvitation(
            region: configuration.region,
            table: configuration.table,
            fleetID: configuration.fleetID
        )
    }

    static func decode(_ data: Data) throws -> FleetEnrollmentInvitation {
        do {
            return try FleetJSON.decoder
                .decode(FleetEnrollmentInvitation.self, from: data)
                .validated()
        } catch let error as FleetEnrollmentInvitationError {
            throw error
        } catch {
            throw FleetEnrollmentInvitationError.unreadableFile
        }
    }

    func encoded() throws -> Data {
        try FleetJSON.encoder.encode(validated())
    }

    func validated() throws -> FleetEnrollmentInvitation {
        try validate()
        return self
    }

    var suggestedFilename: String {
        "FleetMesh-\(fleetID)-invitation"
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FleetEnrollmentInvitationError.unsupportedSchema(schemaVersion)
        }
        guard reporterProfileHint == Self.defaultReporterProfileHint,
              suggestedRole == .workstation else {
            throw FleetEnrollmentInvitationError.invalidSelectors
        }
        var state = LocalDeviceState(
            machineID: "00000000-0000-4000-8000-000000000000",
            fleetRootPath: "/"
        )
        state.storageBackend = .dynamodb
        state.awsProfile = reporterProfileHint
        state.awsRegion = region
        state.dynamoDBTable = table
        state.fleetID = fleetID
        do {
            _ = try state.dynamoDBConfiguration()
        } catch {
            throw FleetEnrollmentInvitationError.invalidSelectors
        }
    }
}

struct FleetEnrollmentInvitationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.fleetMeshInvitation, .json] }
    static var writableContentTypes: [UTType] { [.fleetMeshInvitation] }

    let invitation: FleetEnrollmentInvitation

    init(invitation: FleetEnrollmentInvitation) {
        self.invitation = invitation
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw FleetEnrollmentInvitationError.unreadableFile
        }
        invitation = try FleetEnrollmentInvitation.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try invitation.encoded())
    }
}

enum FleetEnrollmentInvitationError: LocalizedError, Equatable {
    case dynamoDBAuthorityRequired
    case unsupportedSchema(Int)
    case invalidSelectors
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .dynamoDBAuthorityRequired:
            "Connect and verify DynamoDB authority before creating a Mac invitation."
        case .unsupportedSchema(let version):
            "This invitation uses unsupported FleetMesh enrollment schema v\(version)."
        case .invalidSelectors:
            "The invitation contains an invalid Region, table, fleet ID, or reporter profile hint."
        case .unreadableFile:
            "FleetMesh could not read a valid enrollment invitation from this file."
        }
    }
}
