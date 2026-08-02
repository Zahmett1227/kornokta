import Foundation

/// Faz 0 Apple Vision spike (ANA-PLAN §10.1, §25).
///
/// Runs on-device OCR over the gold-set images and writes JSON that the Python
/// evaluation tools score. Deliberately a plain command-line tool: the point of
/// Faz 0 is to measure OCR quality, not to build app screens.

let usage = """
Kullanım:
  AppleVisionSpike --input <klasör|görüntü> --output <sonuc.json> [seçenekler]

Seçenekler:
  --input <yol>        Görüntü dosyası veya görüntü içeren klasör (zorunlu)
  --output <yol>       Yazılacak JSON dosyası (zorunlu)
  --languages tr-TR,en-US   Tanıma dilleri (varsayılan: tr-TR,en-US)
  --language-correction     Dil düzeltmesini AÇ (varsayılan kapalı, bkz. §0.5)
  --list-languages          Bu cihazın desteklediği dilleri yazdır ve çık
  --help
"""

/// Prints what this device can recognize. Vision ignores a language it does
/// not support instead of failing, so a missing language shows up as bad
/// accuracy rather than as an error — this makes it checkable in one command.
func printSupportedLanguages() {
    do {
        let supported = try VisionOCR.supportedLanguages()
        print("Bu cihazın desteklediği tanıma dilleri (\(supported.count)):")
        for language in supported.sorted() {
            print("  \(language)")
        }
        let turkish = supported.filter { $0.lowercased().hasPrefix("tr") }
        print("")
        print(turkish.isEmpty
              ? "Türkçe DESTEKLENMİYOR. --languages tr-TR istense de yok sayılır."
              : "Türkçe destekleniyor: \(turkish.joined(separator: ", "))")
    } catch {
        FileHandle.standardError.write("Dil listesi alınamadı: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

func parseArguments() -> (input: URL, output: URL, languages: [String], correction: Bool)? {
    var input: String?
    var output: String?
    var languages = ["tr-TR", "en-US"]
    var correction = false

    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        switch args[index] {
        case "--input":
            index += 1
            input = index < args.count ? args[index] : nil
        case "--output":
            index += 1
            output = index < args.count ? args[index] : nil
        case "--languages":
            index += 1
            if index < args.count {
                languages = args[index].split(separator: ",").map(String.init)
            }
        case "--language-correction":
            correction = true
        case "--help", "-h":
            return nil
        default:
            FileHandle.standardError.write("Bilinmeyen seçenek: \(args[index])\n".data(using: .utf8)!)
            return nil
        }
        index += 1
    }

    guard let input, let output else { return nil }
    return (URL(fileURLWithPath: input), URL(fileURLWithPath: output), languages, correction)
}

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

func collectImages(at url: URL) -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return []
    }
    if !isDirectory.boolValue {
        return imageExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
    }
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )) ?? []
    return contents
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// Handled before argument validation so it works without --input/--output.
if CommandLine.arguments.contains("--list-languages") {
    printSupportedLanguages()
    exit(0)
}

guard let options = parseArguments() else {
    print(usage)
    exit(1)
}

let images = collectImages(at: options.input)
guard !images.isEmpty else {
    FileHandle.standardError.write("Girdi yolunda görüntü bulunamadı: \(options.input.path)\n".data(using: .utf8)!)
    exit(1)
}

// Prepare the destination *before* running OCR. Discovering an unwritable
// output path after recognizing every page throws away all of that work.
let outputDirectory = options.output.deletingLastPathComponent()
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(
        "Çıktı klasörü oluşturulamadı: \(outputDirectory.path)\n\(error)\n".data(using: .utf8)!
    )
    exit(1)
}

// Say out loud when a requested language is not available. Vision drops it
// silently, and the resulting mis-recognition is easy to read as "OCR is bad"
// when the real cause is "that language was never used" (§0.5).
let supportedLanguages = (try? VisionOCR.supportedLanguages()) ?? []
let unsupportedLanguages = supportedLanguages.isEmpty
    ? []
    : options.languages.filter { !supportedLanguages.contains($0) }
if !unsupportedLanguages.isEmpty {
    FileHandle.standardError.write("""
    UYARI: bu cihaz şu dilleri desteklemiyor: \(unsupportedLanguages.joined(separator: ", "))
           Vision bunları sessizce yok sayar; sonuçlar kalan dillerle üretildi.
           Tam liste için: --list-languages

    """.data(using: .utf8)!)
}

let ocr = VisionOCR(languages: options.languages, usesLanguageCorrection: options.correction)
var pages: [OCRPage] = []

for image in images {
    do {
        let page = try ocr.recognize(imageAt: image)
        pages.append(page)
        print("OK   \(image.lastPathComponent)  satır=\(page.lines.count)  \(page.elapsedMs) ms")
    } catch {
        FileHandle.standardError.write("HATA \(image.lastPathComponent): \(error)\n".data(using: .utf8)!)
    }
}

let run = OCRRun(
    generatedBy: "AppleVisionSpike",
    requestedLanguages: options.languages,
    supportedLanguages: supportedLanguages,
    unsupportedLanguages: unsupportedLanguages,
    pages: pages
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

do {
    let data = try encoder.encode(run)
    // .atomic so an interrupted run cannot leave a half-written report that
    // the Python scorer would then fail to parse.
    try data.write(to: options.output, options: .atomic)
    print("\nYazıldı: \(options.output.path)  (\(pages.count) sayfa)")
    if !options.correction {
        print("Not: dil düzeltmesi KAPALI — sessiz düzeltme yapılmasın diye (§0.5).")
    }
    if !unsupportedLanguages.isEmpty {
        print("Not: \(unsupportedLanguages.joined(separator: ", ")) desteklenmiyor; "
              + "bu sonuçlar o dil olmadan üretildi.")
    }
} catch {
    FileHandle.standardError.write("JSON yazılamadı: \(error)\n".data(using: .utf8)!)
    exit(1)
}
