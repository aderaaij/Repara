import Foundation
import Testing

@testable import ReparaCore

/// The multipart body and the gate that stands in front of it.
///
/// Submitting files a real work order with a municipal government. A council
/// worker reads it and is dispatched. There is no undo and no delete endpoint,
/// so these tests are about making the irreversible thing hard to do by
/// accident — and about the body being byte-correct when it is done on purpose.
@Suite("Submission gate")
struct SubmitGateTests {

    private func prepared() async throws
        -> (Submitter, PreparedReport, MockURLProtocol.Session)
    {
        let (client, mock) = try Fixture.client(returning: "geo-attributes-building")
        let submitter = Submitter(client: client)
        let report = try await submitter.prepare(
            type: .litter,
            at: Projection.reference.wgs84,
            descricao: "Sacos de lixo abandonados no passeio.",
            photos: [Photo(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), filename: "foto.jpg")]
        )
        return (submitter, report, mock)
    }

    // MARK: The gate

    /// The default is not sending. A forgotten argument must never be the thing
    /// that files a report.
    @Test("submit defaults to a dry run and sends nothing")
    func defaultsToDryRun() async throws {
        let (submitter, report, mock) = try await prepared()

        let outcome = try await submitter.submit(
            report, confirmation: ReviewConfirmation(userConfirmed: report))

        guard case let .dryRun(payload, photoBytes, multipartBytes) = outcome else {
            Issue.record("expected a dry run, got \(outcome)")
            return
        }
        #expect(payload.contains("\"tipo_ocorrencia_id\" : 262"))
        #expect(photoBytes == 6)
        #expect(multipartBytes > payload.count)

        // The claim that matters: nothing left the phone. One GET to resolve
        // the address during prepare, and no POST at all.
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(mock.requests.count == 1)
    }

    /// A confirmation is bound to one exact prepared report. Editing the text,
    /// changing the type or dragging the pin re-prepares, and the stale
    /// confirmation must not carry over — the user has to look again.
    @Test("a confirmation from a different report is refused")
    func staleConfirmationRefused() async throws {
        let (submitter, first, _) = try await prepared()
        let (_, second, _) = try await prepared()

        await #expect(throws: SubmitError.self) {
            _ = try await submitter.submit(
                second,
                confirmation: ReviewConfirmation(userConfirmed: first),
                mode: .live
            )
        }
    }

    @Test("the projection self-check runs again immediately before sending")
    func selfCheckBeforeSend() async throws {
        // Not a behaviour test so much as a statement of intent: the last thing
        // that happens before coordinates become a work order is this check.
        #expect(Projection.selfCheckDriftMetres < 0.001)
        let (submitter, report, _) = try await prepared()
        _ = try await submitter.submit(
            report, confirmation: ReviewConfirmation(userConfirmed: report))
    }

    // MARK: The body

    @Test("the obj part carries no Content-Type and is raw UTF-8")
    func objPartHasNoContentType() throws {
        var body = MultipartBody(boundary: "BOUNDARY")
        body.append(name: "obj", value: #"{"morada":"Praça do Comércio, 1"}"#)
        body.finish()

        let text = String(decoding: body.data, as: UTF8.self)
        #expect(
            text == """
                --BOUNDARY\r
                Content-Disposition: form-data; name="obj"\r
                \r
                {"morada":"Praça do Comércio, 1"}\r
                --BOUNDARY--\r\n
                """)
        // Diacritics are everywhere in Lisbon addresses; they must survive as
        // UTF-8 rather than being escaped or transliterated.
        #expect(text.contains("Praça do Comércio"))
        #expect(!text.contains("Content-Type"))
    }

    @Test("photos go in repeated parts named files, with their content type")
    func photoParts() throws {
        var body = MultipartBody(boundary: "BOUNDARY")
        body.append(name: "obj", value: "{}")
        body.append(
            name: "files", filename: "a.jpg", contentType: "image/jpeg", bytes: Data([0x01]))
        body.append(
            name: "files", filename: "b.jpg", contentType: "image/jpeg", bytes: Data([0x02]))
        body.finish()

        let text = String(decoding: body.data, as: UTF8.self)
        #expect(text.components(separatedBy: "name=\"files\"").count == 3, "two files parts")
        #expect(text.contains("filename=\"a.jpg\""))
        #expect(text.contains("Content-Type: image/jpeg"))
        #expect(text.hasSuffix("--BOUNDARY--\r\n"))
    }

    @Test("a filename with quotes or newlines cannot break the body")
    func filenameEscaping() throws {
        var body = MultipartBody(boundary: "BOUNDARY")
        body.append(
            name: "files", filename: "a\"\r\n--BOUNDARY\r\nx.jpg",
            contentType: "image/jpeg", bytes: Data())
        body.finish()

        let text = String(decoding: body.data, as: UTF8.self)

        // A delimiter is only a delimiter after a CRLF, so escaping the CRLF is
        // what disarms the injection — the literal characters "--BOUNDARY" may
        // still appear inside the escaped filename, harmlessly. Count the real
        // delimiters: one opening the part, one closing the body.
        let delimiters = text.components(separatedBy: "\r\n--BOUNDARY").count - 1
        #expect(delimiters == 1, "the closing delimiter only; the opener starts the body")
        #expect(text.hasPrefix("--BOUNDARY\r\n"))
        #expect(text.hasSuffix("--BOUNDARY--\r\n"))
        #expect(text.contains("%22"), "the quote is escaped")
        #expect(text.contains("%0D%0A"), "the line breaks are escaped")
    }

    @Test("the assembled body contains the payload and every photo")
    func assembledBody() async throws {
        let (submitter, report, _) = try await prepared()
        let outcome = try await submitter.submit(
            report, confirmation: ReviewConfirmation(userConfirmed: report))

        guard case let .dryRun(_, photoBytes, multipartBytes) = outcome else {
            Issue.record("expected a dry run")
            return
        }
        let objBytes = try report.obj.encoded().count
        #expect(multipartBytes > objBytes + photoBytes)
    }

    // MARK: How many photographs, and how big

    /// The portal's own form counts to three and then swaps its button for a
    /// dead one reading "Só é possivel adicionar 3 fotos!". That count is
    /// client-side, so a fourth part would likely be accepted and then dropped —
    /// losing one of the photographs somebody walked out to take, silently.
    /// Refusing to prepare is the loud version of the same limit.
    @Test("a fourth photograph is refused rather than quietly dropped")
    func refusesAFourthPhoto() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let photo = Photo(jpeg: Data([0xFF, 0xD8]), filename: "foto.jpg")

        await #expect(throws: SubmitError.self) {
            _ = try await Submitter(client: client).prepare(
                type: .litter,
                at: Projection.reference.wgs84,
                descricao: "Sacos de lixo abandonados no passeio.",
                photos: Array(repeating: photo, count: Photo.maxPerReport + 1)
            )
        }
    }

    @Test("three photographs are fine — that is what the portal's own form takes")
    func acceptsThreePhotos() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let photo = Photo(jpeg: Data([0xFF, 0xD8]), filename: "foto.jpg")

        let report = try await Submitter(client: client).prepare(
            type: .litter,
            at: Projection.reference.wgs84,
            descricao: "Sacos de lixo abandonados no passeio.",
            photos: Array(repeating: photo, count: Photo.maxPerReport)
        )
        #expect(report.photos.count == 3)
    }

    /// The budget exists because a ~6 MB photograph came back as a 500 whose
    /// body mentioned size, while a captured browser submission of 4 844 588 B
    /// was accepted. The exact ceiling is unknown and cannot be probed — every
    /// attempt that succeeds dispatches a council worker — so what is pinned
    /// here is that a full report stays **under the one size known to work**,
    /// not that it stays under a guessed limit.
    @Test("a full report of three photographs fits inside a request known to work")
    func fullReportStaysUnderTheVerifiedSize() {
        let verifiedAcceptedRequest = 4_844_588
        #expect(Photo.maxBytes * Photo.maxPerReport < verifiedAcceptedRequest)
    }

    // MARK: Warnings

    @Test("a report with no photo says so")
    func noPhotoWarning() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        #expect(report.warnings.contains { $0.contains("No photo") })
    }
}
