import Foundation

/// Parser for `.hwpx`, the OWPML (zip + XML) successor to the binary `.hwp`.
///
/// Body text lives in `Contents/section0.xml`, where `<hp:p>` is a paragraph and
/// `<hp:t>` holds runs of text. Tables nest paragraphs inside `<hp:tbl>` cells, so
/// we track table depth and report it as the paragraph level — the same shape the
/// binary parser produces.
enum HwpxParser {
    static func parse(data: Data) throws -> [Paragraph] {
        guard let zip = ZipArchive(data: data) else { throw HwpError.notCompoundFile }

        let sections = zip.entries
            .map(\.name)
            .filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
            .sorted { lhs, rhs in
                (Int(lhs.filter(\.isNumber)) ?? 0) < (Int(rhs.filter(\.isNumber)) ?? 0)
            }
        guard !sections.isEmpty else { throw HwpError.noFileHeader }

        var result: [Paragraph] = []
        for name in sections {
            guard let xml = zip.read(name) else { continue }
            let delegate = SectionDelegate()
            let parser = XMLParser(data: xml)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            guard parser.parse() else { continue }
            result.append(contentsOf: delegate.paragraphs)
        }
        return result
    }

    private final class SectionDelegate: NSObject, XMLParserDelegate {
        private(set) var paragraphs: [Paragraph] = []
        private var buffer = ""
        private var tableDepth = 0
        private var inText = false

        private func localName(_ name: String) -> String {
            name.contains(":") ? String(name.split(separator: ":").last!) : name
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch localName(elementName) {
            case "tbl":
                tableDepth += 1
            case "p":
                buffer = ""
            case "t":
                inText = true
            case "lineBreak", "linesegarray":
                if inText { buffer += " " }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch localName(elementName) {
            case "tbl":
                tableDepth = max(0, tableDepth - 1)
            case "t":
                inText = false
            case "p":
                let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    paragraphs.append(Paragraph(text: line, level: tableDepth))
                }
                buffer = ""
            default:
                break
            }
        }
    }
}
