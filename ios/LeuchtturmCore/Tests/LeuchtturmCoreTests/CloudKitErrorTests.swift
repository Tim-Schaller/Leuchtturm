#if canImport(CloudKit)
import CloudKit
import Testing
@testable import LeuchtturmCore

struct CloudKitErrorTests {
    /// A cancelled request is a cancellation, so the app shows no error for it.
    @Test func cancelledOperationsAreCancellations() async {
        await #expect(throws: CancellationError.self) {
            try await mapCloudKitErrors { () -> Int in throw CKError(.operationCancelled) }
        }
        await #expect(throws: BackendError.network) {
            try await mapCloudKitErrors { () -> Int in throw CKError(.networkFailure) }
        }
    }
}
#endif
