import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import VitalCore

@Suite("Research client")
struct ResearchClientTests {
    let config = SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "sb_publishable_x")
    let t0 = Date(timeIntervalSince1970: 1_791_900_000) // 2026-10-13
    let userId = UUID()

    func client(_ responses: [(Int, String)]) -> (ResearchClient, RecordingTransport) {
        let transport = RecordingTransport(responses)
        let session = AuthSession(accessToken: "jwt", refreshToken: "r", expiresAt: t0.addingTimeInterval(3600), userId: userId, email: nil)
        let auth = SupabaseAuth(config: config, transport: transport, storage: InMemorySessionStorage(session), time: FixedTimeSource(t0))
        return (ResearchClient(config: config, transport: transport, auth: auth), transport)
    }

    static let cardJSON = #"""
    {"cached":false,"insight_id":"3f1c2d4e-0000-4000-8000-000000000001","triage":null,"card":{
      "name":"BPC-157","query":"BPC-157","category":"peptide_investigational","mechanism":"A synthetic peptide.",
      "studied_applications":[{"application":"Tendon healing","summary":"Rodent studies.","evidence":{"level":"preclinical_animal","claimed_level":"established_human","label":"Animal studies only","explanation":"Findings come from animal studies.","model_explanation":"","capped":true,"cap_reason":"Capped","supported_by":"2 animal studies"},
        "citations":[{"source":"pubmed","id":"90000001","title":"[FIXTURE] rats","year":2019,"url":"https://pubmed.ncbi.nlm.nih.gov/90000001/","publication_types":["Journal Article"],"study_kind":"animal","retrieved_at":"2026-10-14T12:00:00.000Z"}]}],
      "evidence":{"level":"preliminary_human","claimed_level":"established_human","label":"Preliminary human evidence","explanation":"Only small studies.","model_explanation":"x","capped":true,"cap_reason":"Claimed established","supported_by":"1 case series"},
      "preclinical_findings":"Faster healing in rats.",
      "anecdotal_reports":{"summary":"Online reports.","verified":false,"label":"Unverified anecdotal reports","biases":[{"name":"Placebo effect","explanation":"..."}]},
      "risks_unknowns":["Unknown long-term effects."],
      "regulatory_status":{"fda":"no_label_found","summary":"No FDA label.","wada":{"status":"unknown","note":"Check WADA."},"sources":[],"checked_at":"2026-10-14"},
      "contraindications_interactions":[{"with":"Lisinopril, Vitamin D3","kind":"no_data","severity":"unknown","detail":"No data.","source":"no_data"}],
      "interaction_considerations":[],"established_approaches":[{"name":"Exercise therapy / physical therapy","kind":"non_drug","note":"First-line."}],
      "comparison_to_established":"Exercise has stronger evidence.","personalized_note":"","dosing_note":"Dosing information is intentionally not provided.",
      "citations":[{"source":"pubmed","id":"90000005","title":"[FIXTURE] case series","year":2022,"url":"https://pubmed.ncbi.nlm.nih.gov/90000005/","publication_types":["Case Reports"],"study_kind":"case_report","retrieved_at":"2026-10-14T12:00:00.000Z"},
                   {"source":"clinicaltrials","id":"NCT90000001","title":"[FIXTURE] trial","year":2024,"url":"https://clinicaltrials.gov/study/NCT90000001","publication_types":["INTERVENTIONAL"],"study_kind":"trial_registration","retrieved_at":"2026-10-14T12:00:00+00:00"}],
      "sources_checked":[{"source":"pubmed","ok":true,"cached":false,"fetched_at":"2026-10-14T12:00:00.000Z"},{"source":"fda_label","ok":true,"cached":true,"fetched_at":"2026-10-14T12:00:00+00:00","note":"no label found"}],
      "dropped_citation_ids":["99999999"],"guard_applied":["dosing_removed","evidence_capped"],
      "research_retrieved_at":"2026-10-14T12:00:00.000Z","last_verified_at":"2026-10-14T12:00:01.000Z","disclaimer":"Educational."}}
    """#

    @Test func insightCardRequestAndDecoding() async throws {
        let (c, t) = client([(200, Self.cardJSON)])
        let r = try await c.insightCard(compound: "BPC-157", question: "Will it help my knee?")
        let card = try #require(r.card)
        #expect(card.evidence.level == .preliminary && card.evidence.claimedLevel == .established && card.evidence.capped)
        #expect(card.studiedApplications[0].evidence.level == .preclinicalAnimal)
        #expect(card.anecdotalReports?.verified == false)
        #expect(card.regulatoryStatus?.fdaDisplayName == "No FDA drug label found")
        #expect(card.contraindicationsInteractions[0].kind == "no_data")
        #expect(card.citationsBySource.map(\.0) == [.pubmed, .clinicaltrials])
        #expect(card.citations[0].studyKindLabel == "Case report/series")
        #expect(card.lastVerifiedAt != nil && card.sourcesChecked[1].cached == true)
        #expect(card.droppedCitationIds == ["99999999"])
        #expect(r.insightId != nil && r.stopped == nil)
        let req = await t.all()[0]
        #expect(req.url?.absoluteString == "https://example.supabase.co/functions/v1/research")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        let sent = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(sent["op"] as? String == "insight_card")
        #expect(sent["compound"] as? String == "BPC-157")
        #expect(sent["question"] as? String == "Will it help my knee?")
    }

    @Test func triageStopDecodes() async throws {
        let body = #"{"triage":{"level":"urgent","stop":true,"flags":[{"id":"cant_bear_weight","label":"being unable to bear weight","level":"urgent"}],"message":"Please get assessed today."},"card":null,"stopped":true}"#
        let (c, _) = client([(200, body)])
        let r = try await c.insightCard(compound: "BPC-157", question: "I can't bear weight")
        #expect(r.card == nil && r.stopped == true)
        #expect(r.triage?.level == .urgent && r.triage?.stop == true && r.triage?.flags.first?.id == "cant_bear_weight")
        #expect(TriageLevel.emergency > .urgent)
    }

    @Test func evidenceLevelOrderingAndText() throws {
        #expect(EvidenceLevel.allCases.sorted().first == .insufficient)
        #expect(EvidenceLevel.allCases.sorted().last == .established)
        #expect(EvidenceLevel.preclinicalAnimal < .preliminary)
        #expect(EvidenceLevel.preliminary.isHumanEvidence && !EvidenceLevel.preclinicalAnimal.isHumanEvidence)
        for l in EvidenceLevel.allCases { #expect(!l.displayName.isEmpty && !l.explanation.isEmpty) }
        let unknown = try VitalJSON.decoder().decode([EvidenceLevel].self, from: Data(#"["moderate_human","super_strong"]"#.utf8))
        #expect(unknown == [.moderate, .insufficient])
    }

    @Test func discoverDecodesAndOrdersNonDrugFirst() async throws {
        let ev = { (l: String) in #"{"level":"\#(l)","capped":false}"# }
        let body = #"{"summary":"S","cached":false,"generated_at":"2026-10-14T12:00:00.000Z","additional_topics":[{"name":"Sleep","search_term":"sleep chronic pain","category":"lifestyle","why":"w"}],"suggestions":[{"candidate_id":"knee_topical_nsaid","name":"Topical NSAIDs","category":"otc","kind":"otc","reason_tags":["knee pain"],"why_relevant":"w","evidence":\#(ev("established_human")),"cautions":[],"interaction_flags":[{"with":"Lisinopril","kind":"drug_interaction","severity":"caution","detail":"d","source":"curated_rule"}],"citations":[],"already_in_routine":false,"summarized_by_model":true},{"candidate_id":"knee_exercise_therapy","name":"Exercise therapy","category":"exercise_rehab","kind":"non_drug","reason_tags":["knee pain"],"why_relevant":"w","evidence":\#(ev("established_human")),"cautions":[],"interaction_flags":[],"citations":[],"already_in_routine":false,"summarized_by_model":true}]}"#
        let (c, t) = client([(200, body)])
        let r = try await c.discover(concern: "knee pain", max: 6, now: t0, timeZone: TimeZone(identifier: "UTC")!)
        #expect(r.suggestions.count == 2)
        #expect(r.nonDrugFirst.first?.candidateId == "knee_exercise_therapy")
        #expect(r.suggestions[0].interactionFlags[0].severityDisplayName.contains("caution"))
        #expect(r.additionalTopics?.first?.searchTerm == "sleep chronic pain")
        let sent = try JSONSerialization.jsonObject(with: await t.all()[0].httpBody!) as! [String: Any]
        #expect(sent["op"] as? String == "discover" && sent["max"] as? Int == 6 && sent["local_date"] as? String == "2026-10-13")
    }

    @Test func interestsAlertsAndErrors() async throws {
        let iid = UUID(), aid = UUID()
        let (c, t) = client([
            (200, #"{"interest":{"id":"\#(iid.uuidString.lowercased())","kind":"compound","term":"BPC-157","display_name":null,"created_at":"2026-10-14T12:00:00+00:00","last_checked_at":null},"created":true}"#),
            (200, #"{"checked":1,"checked_at":"2026-10-14T12:00:00.000Z","alerts":[{"id":"\#(aid.uuidString.lowercased())","interest_id":"\#(iid.uuidString.lowercased())","kind":"new_meta_analysis","title":"New meta-analysis: BPC-157","summary":"T (2026)","citation":{"source":"pubmed","id":"90000011","title":"T","year":2026,"url":"https://pubmed.ncbi.nlm.nih.gov/90000011/","publication_types":["Meta-Analysis"],"study_kind":"meta_analysis"},"created_at":"2026-10-14T12:00:00+00:00","seen_at":null}]}"#),
            (204, ""),
            (403, #"{"error":"consent_required","message":"Turn on AI"}"#),
        ])
        let interest = try await c.addInterest("BPC-157")
        #expect(interest.id == iid && interest.title == "BPC-157")
        let updates = try await c.checkUpdates(force: true)
        #expect(updates.checked == 1 && updates.alerts[0].kindDisplayName == "New meta-analysis")
        #expect(ResearchAlertNotifier.toNotify(updates.alerts, alreadyNotified: []).count == 1)
        #expect(ResearchAlertNotifier.toNotify(updates.alerts, alreadyNotified: [aid]).isEmpty)
        try await c.markAlertSeen(aid, at: t0)
        await #expect(throws: CoachError.consentRequired("Turn on AI")) { try await c.discover(now: t0) }
        let reqs = await t.all()
        let addBody = try JSONSerialization.jsonObject(with: reqs[0].httpBody!) as! [String: Any]
        #expect(addBody["op"] as? String == "interests_add" && addBody["kind"] as? String == "compound")
        let checkBody = try JSONSerialization.jsonObject(with: reqs[1].httpBody!) as! [String: Any]
        #expect(checkBody["force_refresh"] as? Bool == true)
        #expect(reqs[2].httpMethod == "PATCH" && reqs[2].url!.path.hasSuffix("/rest/v1/research_alerts"))
        #expect(reqs[2].url!.query == "id=eq.\(aid.uuidString.lowercased())")
        #expect(String(decoding: reqs[2].httpBody!, as: UTF8.self).contains("2026-10-13"))
    }

    @Test func coachMetadataCarriesResearchTopics() throws {
        let m = try VitalJSON.decoder().decode(CoachMetadata.self, from: Data(#"{"basis":"general_education","research_topics":["BPC-157"]}"#.utf8))
        #expect(m.researchTopics == ["BPC-157"])
    }
}
