import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import VitalCore

@Suite("Coach client")
struct CoachClientTests {
    let config = SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "sb_publishable_x")
    let t0 = Date(timeIntervalSince1970: 1_791_900_000) // 2026-10-13
    let userId = UUID()

    func client(_ responses: [(Int, String)]) -> (CoachClient, RecordingTransport) {
        let transport = RecordingTransport(responses)
        let session = AuthSession(accessToken: "jwt", refreshToken: "r", expiresAt: t0.addingTimeInterval(3600), userId: userId, email: nil)
        let auth = SupabaseAuth(config: config, transport: transport, storage: InMemorySessionStorage(session), time: FixedTimeSource(t0))
        return (CoachClient(config: config, transport: transport, auth: auth), transport)
    }

    @Test func chatRequestShapeAndDecoding() async throws {
        let conv = UUID(), msg = UUID()
        let body = #"{"conversation_id":"\#(conv.uuidString.lowercased())","proposed_memories":1,"goal_proposal":null,"message":{"id":"\#(msg.uuidString.lowercased())","conversation_id":"\#(conv.uuidString.lowercased())","role":"assistant","content":"Hi","metadata":{"basis":"your_data","data_points_used":["Weight (Oct 6–12)"],"follow_up_question":"How did you sleep?","safety":{"urgent":false,"needs_clinician":true,"topics":["hormone"]},"guard_applied":["clinician_notice"]},"created_at":"2026-10-13T15:00:00.123456+00:00"}}"#
        let (c, t) = client([(200, body)])
        let r = try await c.send(.chat, message: "hello", conversationId: conv, timeZone: TimeZone(identifier: "America/Chicago")!, now: t0)
        #expect(r.conversationId == conv)
        #expect(r.message?.content == "Hi")
        #expect(r.message?.metadata?.basisLabel == "Based on your data")
        #expect(r.message?.metadata?.followUpQuestion == "How did you sleep?")
        #expect(r.message?.metadata?.safety?.needsClinician == true)
        #expect(r.proposedMemories == 1)
        let req = await t.all()[0]
        #expect(req.url?.absoluteString == "https://example.supabase.co/functions/v1/coach")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        #expect(req.value(forHTTPHeaderField: "apikey") == "sb_publishable_x")
        let sent = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(sent["mode"] as? String == "chat")
        #expect(sent["timezone"] as? String == "America/Chicago")
        #expect(sent["local_date"] as? String == "2026-10-13")
        #expect(sent["conversation_id"] as? String == conv.uuidString.lowercased())
    }

    @Test func errorsMapToFriendlyCases() async {
        let cases: [((Int, String), CoachError)] = [
            ((403, #"{"error":"consent_required","message":"Turn on AI"}"#), .consentRequired("Turn on AI")),
            ((429, #"{"error":"daily_limit","message":"Limit"}"#), .limitReached(code: "daily_limit", message: "Limit")),
            ((503, #"{"error":"coach_not_configured","message":"Not set up"}"#), .notConfigured("Not set up")),
            ((404, "{}"), .notConfigured("The coach service isn't deployed yet.")),
            ((502, #"{"error":"provider_unavailable","message":"Try later"}"#), .unavailable("Try later")),
            ((401, "{}"), .unauthorized),
        ]
        for (resp, expected) in cases {
            let (c, _) = client([resp])
            await #expect(throws: expected) { try await c.send(.chat, message: "x", now: t0) }
        }
    }

    @Test func insightAndMemoryDecoding() async throws {
        let insightId = UUID(), memId = UUID()
        let (c, t) = client([
            (200, #"[{"id":"\#(insightId.uuidString.lowercased())","kind":"goal_proposal","for_date":"2026-10-13","title":"Suggested goal change","body":"Stiffness is high","payload":{"add":["mobility","nonsense"],"remove":["fat_loss"],"rationale":"r"},"status":"new","created_at":"2026-10-13T15:00:00+00:00"}]"#),
            (200, #"[{"id":"\#(memId.uuidString.lowercased())","category":"preference","content":"Short answers","source":"coach","status":"proposed","created_at":"2026-10-13T15:00:00+00:00"}]"#),
            (204, ""),
            (204, ""),
        ])
        let insights = try await c.insights()
        #expect(insights[0].payload?.goalsToAdd == [.mobility])
        #expect(insights[0].payload?.goalsToRemove == [.fatLoss])
        let memories = try await c.memories()
        #expect(memories[0].status == .proposed && memories[0].category == .preference)
        try await c.updateMemory(memId, status: .active)
        try await c.clearMemory()
        let reqs = await t.all()
        #expect(reqs[1].url!.query!.contains("status=in.(proposed,active)"))
        #expect(reqs[2].httpMethod == "PATCH")
        #expect(reqs[2].url!.query == "id=eq.\(memId.uuidString.lowercased())")
        #expect(String(decoding: reqs[2].httpBody!, as: UTF8.self) == #"{"status":"active"}"#)
        #expect(reqs[3].httpMethod == "DELETE")
        #expect(reqs[3].url!.query == "id=not.is.null")
    }

    @Test func goalProposalApplierNeverEmptiesGoals() {
        var p = InsightPayload()
        p.add = ["mobility"]; p.remove = ["fat_loss"]
        #expect(GoalProposalApplier.apply(p, to: [.fatLoss, .strength]) == [.mobility, .strength])
        var removeAll = InsightPayload()
        removeAll.remove = ["strength"]
        #expect(GoalProposalApplier.apply(removeAll, to: [.strength]) == [.strength])
        var nested = InsightPayload()
        nested.goalProposal = .init(add: ["energy"], remove: [], rationale: "r")
        #expect(GoalProposalApplier.apply(nested, to: []) == [.energy])
    }

    @Test func localDateFollowsTimeZone() {
        // 2026-10-13T03:00Z is still Oct 12 in Chicago.
        let d = Date(timeIntervalSince1970: 1_791_860_400)
        #expect(CoachDates.localDate(d, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-13")
        #expect(CoachDates.localDate(d, timeZone: TimeZone(identifier: "America/Chicago")!) == "2026-10-12")
    }
}
