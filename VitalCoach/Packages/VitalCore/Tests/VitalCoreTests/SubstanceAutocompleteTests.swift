import Foundation
import Testing
@testable import VitalCore

@Suite("Smart Routine Entry — substance autocomplete")
struct SubstanceAutocompleteTests {
    func service(_ store: CustomSubstanceStore = InMemoryCustomSubstanceStore()) -> SubstanceAutocompleteService {
        SubstanceAutocompleteService(customStore: store)
    }

    @Test("Peptide: \"tes\" → Tesamorelin")
    func peptidePrefix() async {
        let r = await service().search("tes", category: .peptide)
        #expect(r.first?.name == "Tesamorelin")
        #expect(r.allSatisfy { $0.catalogEntry?.categories.contains(.peptide) ?? false })
    }

    @Test("Prescription: \"met\" → Metformin and Metoprolol first")
    func medicationPrefix() async {
        let r = await service().search("met", category: .prescription)
        #expect(Array(r.prefix(2)).map(\.name) == ["Metformin", "Metoprolol"])
        #expect(r.contains { $0.name == "Methotrexate" })
    }

    @Test("Brand names find the generic and say which alias matched")
    func brandToGeneric() async {
        let s = service()
        let glucophage = await s.search("Glucophage", category: .prescription)
        #expect(glucophage.first?.name == "Metformin")
        #expect(glucophage.first?.matchedAlias == "Glucophage")
        let lipitor = await s.search("lipit", category: .prescription)
        #expect(lipitor.first?.name == "Atorvastatin")
        let generic = await s.search("atorvastatin", category: .prescription)
        #expect(generic.first?.name == "Atorvastatin")
        #expect(generic.first?.matchedAlias == nil)
        let egrifta = await s.search("egrifta", category: .peptide)
        #expect(egrifta.first?.name == "Tesamorelin")
    }

    @Test("Matching is case-, accent- and punctuation-insensitive")
    func caseInsensitive() async {
        let s = service()
        let a = await s.search("METF", category: .prescription).map(\.id)
        let b = await s.search("mEtF", category: .prescription).map(\.id)
        #expect(a == b)
        #expect(a.first == "catalog:metformin")
        #expect(await s.search("bpc157", category: .peptide).first?.name == "BPC-157")
        #expect(await s.search("BPC 157", category: .peptide).first?.name == "BPC-157")
        #expect(await s.search("tb 500", category: .peptide).first?.catalogEntry?.id == "tb-500")
    }

    @Test("Typos within tolerance still match")
    func typoTolerance() async {
        let s = service()
        #expect(await s.search("metforman", category: .prescription).first?.name == "Metformin")
        #expect(await s.search("tesamorlin", category: .peptide).first?.name == "Tesamorelin")
        #expect(await s.search("ashwaganda", category: .sportsSupplement).first?.catalogEntry?.id == "ashwagandha")
        // Short queries are prefix-only: no fuzzy noise.
        #expect(await s.search("xq", category: .prescription).isEmpty)
    }

    @Test("1–2 character queries and abbreviations")
    func shortQueries() async {
        let s = service()
        let d3 = await s.search("d3", category: .vitaminMineral)
        #expect(d3.first?.catalogEntry?.id == "vitamin-d3")
        let one = await s.search("z", category: .vitaminMineral)
        #expect(one.first?.name == "Zinc")
        let trt = await s.search("TRT", category: .hormone)
        #expect(trt.first?.name.hasPrefix("Testosterone") == true)
        let nac = await s.search("nac", category: .sportsSupplement)
        #expect(nac.first?.catalogEntry?.id == "nac")
    }

    @Test("Switching category changes the results")
    func categorySwitch() async {
        let s = service()
        let peptide = await s.search("tes", category: .peptide).map(\.name)
        let hormone = await s.search("tes", category: .hormone).map(\.name)
        #expect(peptide.contains("Tesamorelin"))
        #expect(!hormone.contains("Tesamorelin"))
        #expect(hormone.first?.hasPrefix("Testosterone") == true)
        // Entries listed under several categories appear in each.
        #expect(await s.search("sema", category: .prescription).first?.name == "Semaglutide")
        #expect(await s.search("sema", category: .peptide).first?.name == "Semaglutide")
    }

    @Test("No duplicate rows, even when several aliases match")
    func noDuplicates() async throws {
        let s = service()
        let r = await s.search("testosterone", category: .hormone)
        #expect(Set(r.map(\.id)).count == r.count)
        // A custom entry spelled like a verified one isn't shown twice.
        try await s.addCustom(name: "metformin", category: .prescription)
        let met = await s.search("metformin", category: .prescription)
        #expect(met.filter { SearchText.compact($0.name) == "metformin" }.count == 1)
        #expect(met.first?.isUserCreated == false)
    }

    @Test("Custom entry persists across an app restart and is never added to the catalog")
    func customPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("custom-substances.json")
        let catalogCount = SubstanceCatalog.entries.count

        let first = service(FileCustomSubstanceStore(url: url))
        let saved = try await first.addCustom(name: "  Zeta Peptide Blend  ", category: .peptide,
                                              alternateName: "ZPB", notes: "From my clinic")
        #expect(saved.name == "Zeta Peptide Blend")

        // "Restart": a brand-new service and store reading the same file.
        let second = service(FileCustomSubstanceStore(url: url))
        let r = await second.search("zeta", category: .peptide)
        #expect(r.count == 1)
        #expect(r.first?.isUserCreated == true)
        #expect(r.first?.catalogRef == "custom:\(saved.id.uuidString.lowercased())")
        #expect(await second.search("zpb", category: .peptide).first?.matchedAlias == "ZPB")
        // Category-scoped.
        #expect(await second.search("zeta", category: .hormone).isEmpty)

        // Editable.
        var edited = saved; edited.notes = "Updated"
        try await second.updateCustom(edited)
        let third = service(FileCustomSubstanceStore(url: url))
        #expect(await third.customSubstances().first?.notes == "Updated")

        #expect(SubstanceCatalog.entries.count == catalogCount)
        #expect(!SubstanceCatalog.entries.contains { $0.name == "Zeta Peptide Blend" })
    }

    @Test("Custom entries work fully offline and re-adding returns the same entry")
    func offlineCustom() async throws {
        let store = InMemoryCustomSubstanceStore()
        let s = service(store)
        let a = try await s.addCustom(name: "Clinic Recovery Stack", category: .compounded)
        let b = try await s.addCustom(name: "clinic recovery stack", category: .compounded)
        #expect(a.id == b.id)
        #expect(try await store.load().count == 1)
        await #expect(throws: SubstanceAutocompleteService.CustomError.emptyName) {
            try await s.addCustom(name: "   ", category: .compounded)
        }
    }

    @Test("A failing custom store never blocks search or manual entry")
    func failuresDontBlock() async throws {
        let store = InMemoryCustomSubstanceStore([CustomSubstance(name: "Mystery", category: .prescription)])
        await store.setFailNextLoad(true)
        let s = service(store)
        let r = await s.search("met", category: .prescription)
        #expect(r.first?.name == "Metformin")
        // Manual entry still works after the failure.
        let added = try await s.addCustom(name: "Metabolic Blend X", category: .prescription)
        #expect(await s.search("metabolic blend", category: .prescription).contains { $0.id == "custom:\(added.id.uuidString.lowercased())" })
        // Unknown names simply return nothing (the UI then offers "Add as custom").
        #expect(await s.search("qqqqqqqq", category: .prescription).isEmpty)
    }

    @Test("Existing routines decode unchanged; a nil catalog reference isn't sent")
    func existingRoutinesUnchanged() throws {
        let json = """
        {"id":"7b0c7f0e-8f1a-4d43-9b52-2a7b8d0a1c11","user_id":"3f1d2a4b-5c6d-4e7f-8a9b-0c1d2e3f4a5b","name":"Vitamin D3",
         "aliases":[],"category":"vitamin_mineral","status":"active","is_prescribed":false,
         "created_at":"2026-01-02T03:04:05.000Z","client_updated_at":"2026-01-02T03:04:05.000Z","version":3}
        """
        let s = try VitalJSON.decoder().decode(UserSubstance.self, from: Data(json.utf8))
        #expect(s.catalogRef == nil)
        #expect(s.isUserCreatedName == false)
        #expect(s.version == 3)
        let encoded = String(decoding: try VitalJSON.encoder().encode(s), as: UTF8.self)
        #expect(!encoded.contains("catalog_ref"))
    }

    @Test("Route defaults are context-aware and never injectable for oral tablets")
    func routeDefaults() {
        let byId = Dictionary(uniqueKeysWithValues: SubstanceCatalog.entries.map { ($0.id, $0) })
        #expect(byId["metformin"]?.defaultRoute == .oral)
        #expect(byId["testosterone-cypionate"]?.defaultRoute == nil)   // several routes → user chooses
        #expect(byId["tesamorelin"]?.defaultRoute == .subcutaneous)
        #expect(byId["albuterol"]?.defaultRoute == .inhaled)
    }

    @Test("Catalog integrity: unique ids, names, categories")
    func catalogIntegrity() {
        let entries = SubstanceCatalog.entries
        #expect(Set(entries.map(\.id)).count == entries.count)
        for e in entries {
            #expect(!e.name.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!e.categories.isEmpty)
            #expect((0...100).contains(e.popularity))
        }
        for category in [SubstanceCategory.prescription, .overTheCounter, .peptide, .hormone, .vitaminMineral, .sportsSupplement, .compounded] {
            #expect(SubstanceCatalog.entries(in: category).count >= 10, "\(category) has too few entries")
            let names = SubstanceCatalog.entries(in: category).map { SearchText.compact($0.name) }
            #expect(Set(names).count == names.count, "duplicate names in \(category)")
        }
    }

    @Test("Debounced search is dropped when the user keeps typing")
    func debounce() async {
        let s = service()
        let task = Task { await s.debouncedSearch("met", category: .prescription, delay: .milliseconds(200)) }
        task.cancel()
        #expect(await task.value == nil)
        let done = await s.debouncedSearch("met", category: .prescription, delay: .milliseconds(1))
        #expect(done?.first?.name == "Metformin")
    }
}
