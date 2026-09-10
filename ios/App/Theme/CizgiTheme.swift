import SwiftUI
import CizgiCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Ders yayı
//
// On bir ders, tek bir renk yayı üzerinde: hepsi aynı açıklık ve doygunlukta,
// yalnız ton açısı kayıyor. Bağımsız marka renkleri değil — aynı ölçeğin komşu
// durakları. Karanlık modda hepsinin açık varyantı kullanılır (lacivert
// zeminde 4.5:1 üstü kalsınlar diye).
//
// Tasarım dokuz durakla geldi; `subject_topics.json` on bir ders taşıyor
// (ADR-001 çevresindeki ders/konu sözleşmesi). Eksik iki ders renksiz kalsaydı
// vurguları saatin dersine düşer, `SubjectDistributionBar` de o kartları
// şeritten sessizce düşürürdü — kartlar geçerli, ekran sağlıklı, anlattığı
// deste yanlış. Bu yüzden yay iki durak *uzatıldı*: mevcut dokuz rengin hiçbiri
// değişmedi, yeni ikisi en geniş iki ton boşluğunun ortasına, komşularının
// açıklık/doygunluk ortalamasıyla kondu — "aynı ölçeğin komşu durakları"
// ilkesi korunarak. `cerrahi`'nin görünen adı da kanonik "Genel Cerrahi"ye
// çekildi: "Cerrahi" hiçbir zaman eşleşmiyordu (`matching` tam ad karşılaştırır).
//
// Ders adlarının tek kaynağı `backend/schemas/subject_topics.json`; buradaki
// tablo ondan sapamaz — `evals/tests/test_subject_arc_sync.py` ikisini
// karşılaştırır (App hedefi yalnız Mac'te derlendiği için Swift değil Python).

enum CizgiSubject: String, CaseIterable {
    // Yay sırası (ton açısına göre), enum sırası da bu.
    case patoloji, farmakoloji, fizyoloji, anatomi, biyokimya
    case kucukStajlar, mikrobiyoloji, dahiliye, cerrahi, kadinDogum, pediatri

    /// `SubjectTopicSchema`'nın ders adlarıyla **birebir** eşleşir.
    var displayName: String {
        switch self {
        case .patoloji: return "Patoloji"
        case .farmakoloji: return "Farmakoloji"
        case .fizyoloji: return "Fizyoloji"
        case .anatomi: return "Anatomi"
        case .biyokimya: return "Biyokimya"
        case .kucukStajlar: return "Küçük Stajlar"
        case .mikrobiyoloji: return "Mikrobiyoloji"
        case .dahiliye: return "Dahiliye"
        case .cerrahi: return "Genel Cerrahi"
        case .kadinDogum: return "Kadın Hastalıkları ve Doğum"
        case .pediatri: return "Pediatri"
        }
    }

    var color: Color {
        switch self {
        case .patoloji:      return dyn((0.482, 0.133, 0.188), (0.816, 0.541, 0.565))
        case .farmakoloji:   return dyn((0.541, 0.227, 0.141), (0.847, 0.576, 0.478))
        case .fizyoloji:     return dyn((0.494, 0.333, 0.094), (0.827, 0.659, 0.361))
        case .anatomi:       return dyn((0.416, 0.353, 0.137), (0.769, 0.702, 0.416))
        case .biyokimya:     return dyn((0.247, 0.357, 0.200), (0.576, 0.725, 0.518))
        // Yeni durak: biyokimya (102°) ile mikrobiyoloji (172°) arasında, 137°.
        case .kucukStajlar:  return dyn((0.167, 0.348, 0.218), (0.504, 0.724, 0.565))
        case .mikrobiyoloji: return dyn((0.137, 0.337, 0.310), (0.490, 0.725, 0.686))
        case .dahiliye:      return dyn((0.173, 0.290, 0.420), (0.561, 0.690, 0.831))
        case .cerrahi:       return dyn((0.275, 0.208, 0.420), (0.659, 0.584, 0.824))
        // Yeni durak: cerrahi (259°) ile pediatri (326°) arasında, 293°.
        case .kadinDogum:    return dyn((0.390, 0.186, 0.418), (0.792, 0.566, 0.820))
        case .pediatri:      return dyn((0.416, 0.165, 0.306), (0.816, 0.549, 0.690))
        }
    }

    /// Yumuşak dolgu (seçili sekme diski, işaret şeridi zemini).
    var soft: Color { color.opacity(0.14) }

    /// Depoda duran serbest metni (eski `AppSettings.defaultSubject`) tanımaya
    /// çalışır. Türkçe küçük harf katlaması `lowercased()` ile yeterli çünkü
    /// karşılaştırılan iki taraf da bu tablodan geliyor.
    static func matching(_ raw: String?) -> CizgiSubject? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        return allCases.first { $0.displayName.lowercased() == raw || $0.rawValue == raw }
    }
}

// MARK: - Vurgunun kaynağı

enum CizgiAccentSource: String, CaseIterable {
    /// Öntanımlı: o an çalışılan dersin rengi.
    case subject
    /// Ders bağlamı yoksa (ya da kullanıcı böyle seçtiyse) günün saati.
    case timeOfDay
    /// Kullanıcı bir dersi sabitledi; hiç değişmez.
    case pinned

    var displayName: String {
        switch self {
        case .subject: return "Derse göre"
        case .timeOfDay: return "Zamana göre"
        case .pinned: return "Sabit"
        }
    }
}

enum Cizgi {

    // MARK: Depolanan görünüm ayarları

    enum Keys {
        static let accentSource = "cizgi.accentSource"
        static let pinnedSubject = "cizgi.pinnedSubject"
    }

    /// Ekranların o an hangi derste olduğunu bildirdiği yer. `SubjectPickerBar`
    /// ve `CizgiApp` bunu yazar; okuyan yalnız `accent`.
    ///
    /// Bir `static var` olması bilinçli: eski çağrı yerlerinin hepsi
    /// `Cizgi.accent` yazıyor ve hiçbiri değişmek zorunda kalmıyor. Bedeli,
    /// SwiftUI'ın değişimi görememesi — `didSet` onu `CizgiAppearance`'a
    /// duyurarak kapatıyor.
    static var activeSubject: CizgiSubject? = nil {
        didSet {
            guard oldValue != activeSubject else { return }
            CizgiAppearance.shared.bump()
        }
    }

    static var accentSource: CizgiAccentSource {
        get { CizgiAccentSource(rawValue: UserDefaults.standard.string(forKey: Keys.accentSource) ?? "") ?? .subject }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.accentSource)
            CizgiAppearance.shared.bump()
        }
    }

    static var pinnedSubject: CizgiSubject {
        get { CizgiSubject(rawValue: UserDefaults.standard.string(forKey: Keys.pinnedSubject) ?? "") ?? .patoloji }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.pinnedSubject)
            CizgiAppearance.shared.bump()
        }
    }

    /// Saatin dersi. Rastgele değil, tahmin edilebilir: sabah ısınır, gece soğur.
    static func subjectForTime(_ date: Date = .now) -> CizgiSubject {
        switch Calendar.current.component(.hour, from: date) {
        case 6..<12:  return .farmakoloji   // tuğla
        case 12..<18: return .patoloji      // oxblood
        case 18..<23: return .pediatri      // erik
        default:      return .dahiliye      // lacivert
        }
    }

    /// Tek vurgu. Sabit bir marka rengi değil, bir konum.
    static var accent: Color { accentSubject.color }

    static var accentSubject: CizgiSubject {
        switch accentSource {
        case .pinned: return pinnedSubject
        case .timeOfDay: return subjectForTime()
        case .subject: return activeSubject ?? subjectForTime()
        }
    }

    /// Vurgunun yumuşak dolgusu — çip, disk, şerit zemini.
    static var accentSoft: Color { dyn((0.941, 0.886, 0.878), (0.227, 0.153, 0.200)) }

    // MARK: Nötr palet — kemik kâğıt / lacivert gece

    /// Sıcak grafit: başlık ve gövde.
    static let ink = dyn((0.110, 0.098, 0.090), (0.929, 0.941, 0.965))
    /// İkincil metin.
    static let muted = dyn((0.431, 0.404, 0.365), (0.682, 0.722, 0.796))
    /// Üçüncül: eyebrow, birim etiketi.
    static let faint = dyn((0.541, 0.514, 0.471), (0.486, 0.533, 0.627))
    /// Ekran zemini.
    static let paper = dyn((0.953, 0.941, 0.914), (0.082, 0.106, 0.157))
    /// Kart yüzeyi, liste satırı.
    static let surface = dyn((1.000, 0.992, 0.976), (0.110, 0.141, 0.204))
    /// Gömülü alan, sayaç kutusu.
    static let surfaceMuted = dyn((0.918, 0.898, 0.855), (0.133, 0.173, 0.243))
    /// 1px ayırıcı ve kart kenarı. Gölge yerine çizgi.
    static let hairline = dyn((0.878, 0.851, 0.796), (0.180, 0.227, 0.314))

    static let success = dyn((0.180, 0.361, 0.271), (0.435, 0.718, 0.557))
    static let warning = dyn((0.541, 0.353, 0.071), (0.835, 0.651, 0.341))
    static let danger  = dyn((0.549, 0.184, 0.149), (0.878, 0.502, 0.475))

    // MARK: Boşluk / biçim

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Bir kademe sıkıldı: baloncuk değil, ciltli kitap köşesi.
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 14
        static let lg: CGFloat = 22
    }

    // MARK: Tipografi

    /// Tek gömülü yazı ailesi. Yalnız üç yerde: kart sorusu, boş durum
    /// başlığı, büyük sayı.
    ///
    /// Font pakete konmadıysa `Font.custom` sessizce **sistem sans'ına** düşer,
    /// serife değil — tasarımın serif sesi hiç duyulmadan kaybolurdu. Georgia
    /// iOS'ta her zaman var ve gerçekten serif; `relativeTo:` korunduğu için
    /// Dynamic Type ölçeklemesi de yerinde kalır.
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(isSerifBundled ? serifFamily : "Georgia", size: size, relativeTo: style)
    }

    static let serifFamily = "LibreCaslonText-Regular"

    /// Bir kez bakılır: `UIFont(name:)` yalnız kayıtlı aileler için nil dışı döner.
    #if canImport(UIKit)
    static let isSerifBundled = UIFont(name: serifFamily, size: 12) != nil
    #else
    static let isSerifBundled = false
    #endif

    /// Eski `highlighter` gradyanının yerine geçen düz renk. Adı korunuyor ki
    /// çağrı yerleri (`ReviewView.progressBar`, `CardSurface`) değişmesin.
    static var highlighter: Color { accent }
}

// MARK: - Görünüm yayıncısı

/// Vurgu rengi bir `static var`'dan okunuyor; SwiftUI onu gözlemleyemez, yani
/// ders ya da ayar değişince ekranda kendiliğinden hiçbir şey yenilenmez.
///
/// UYGULAMA.md `.id(Cizgi.accentSubject)` öneriyordu. O yol kökü *kimliğiyle*
/// değiştirir ve alt ağacın bütün `@State`'ini sıfırlar — Egzersiz'in yarım
/// kalan oturumu dahil (`ExerciseView` koşuyu `@State`'te tutar). Bunun yerine
/// tek bir yayıncı: `RootView` onu gözler, değiştiğinde gövdesi yeniden
/// değerlendirilir, sekme çocuklarının gövdeleri de öyle, `Cizgi.accent` taze
/// okunur. Kimlik değişmediği için hiçbir `@State` kaybolmaz.
final class CizgiAppearance: ObservableObject {
    static let shared = CizgiAppearance()
    private init() {}

    /// Yalnız "bir şey değişti" demek için; değerin kendisi anlamsız.
    @Published private(set) var revision = 0

    /// Ana kuyruğa alınır: `@Published`'ı arka plandan yazmak SwiftUI'da
    /// çalışma zamanı uyarısıdır ve `activeSubject` ileride bir kuyruk
    /// geri çağrısından da yazılabilir.
    func bump() {
        if Thread.isMainThread { revision &+= 1 }
        else { DispatchQueue.main.async { self.revision &+= 1 } }
    }
}

// MARK: - Dinamik renk yardımcısı

#if canImport(UIKit)
private func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}
#else
private func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(red: light.0, green: light.1, blue: light.2)
}
#endif

// MARK: - Kart yüzeyi

/// Gölge kalktı, yerine 1px hairline. İşaret şeridi 5px → 3px ve artık üstte:
/// rozet yerine kartın kendisi hangi derste olduğunu söylüyor.
struct CardSurface<Content: View>: View {
    var highlighted: Bool = false
    var subject: CizgiSubject? = nil
    var padding: CGFloat = Cizgi.Space.lg
    @ViewBuilder var content: () -> Content

    private var strip: Color { subject?.color ?? Cizgi.accent }

    var body: some View {
        VStack(spacing: 0) {
            if highlighted {
                strip.frame(height: 3)
            }
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Cizgi.surface)
        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                .stroke(Cizgi.hairline, lineWidth: 1)
        )
    }
}

/// Baklava ayırıcı — soru ile cevap arasındaki kesme.
struct CizgiRule: View {
    var body: some View {
        HStack(spacing: Cizgi.Space.md) {
            Rectangle().fill(Cizgi.hairline).frame(height: 1)
            Rectangle().fill(Cizgi.hairline.opacity(0.9))
                .frame(width: 5, height: 5)
                .rotationEffect(.degrees(45))
            Rectangle().fill(Cizgi.hairline).frame(height: 1)
        }
    }
}

/// Bölüm işareti — açıklama paragrafının başında.
struct CizgiSectionMark: View {
    var body: some View {
        Text("§")
            .font(Cizgi.serif(20))
            .foregroundStyle(Cizgi.hairline)
    }
}

/// Kıvrık köşe — yalnız gözden geçirilmesi gereken kartta.
struct DogEar: View {
    var tint: Color = Cizgi.warning
    var size: CGFloat = 26
    var body: some View {
        Path { p in
            p.move(to: .init(x: size, y: 0))
            p.addLine(to: .init(x: size, y: size))
            p.addLine(to: .init(x: 0, y: 0))
            p.closeSubpath()
        }
        .fill(tint.opacity(0.22))
        .frame(width: size, height: size)
    }
}

/// Konturlu etiket. Dolgu yalnız *seçili* olanı işaretler.
struct TagChip: View {
    let text: String
    var systemImage: String?
    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            // Konu adları uzun olabiliyor ("Kemoterapötikler ve
            // İmmünomodülatörler"): sarmalanan bir kapsül üç satıra şişip
            // kartın başlık satırını dağıtıyordu. Etiket bir *işaret*, bir
            // paragraf değil — kırpılır, tam adı VoiceOver taşır.
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Cizgi.ink)
        .padding(.horizontal, Cizgi.Space.sm)
        .padding(.vertical, Cizgi.Space.xs)
        .background(Cizgi.surfaceMuted, in: Capsule())
        .accessibilityLabel(text)
    }
}

struct SubjectChip: View {
    let subject: CizgiSubject
    let isSelected: Bool
    var body: some View {
        Text(subject.displayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(isSelected ? Cizgi.surface : Cizgi.ink)
            .padding(.horizontal, Cizgi.Space.sm)
            .padding(.vertical, Cizgi.Space.xs)
            .background(isSelected ? subject.color : Cizgi.surfaceMuted, in: Capsule())
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).foregroundStyle(Cizgi.ink)
            Text(label).font(.caption).foregroundStyle(Cizgi.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Cizgi.Space.md)
        .background(Cizgi.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
    }
}

/// Eyebrow artık vurgu renginde değil: harf aralıklı ve `faint`. Renk yerine
/// ağırlık ve aralık farkı.
struct ScreenHero: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// Mürekkep zeminli varyant — bir bölümü diğerlerinden ayırmak için.
    var onInk = false

    var body: some View {
        HStack(alignment: .top, spacing: Cizgi.Space.lg) {
            VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(onInk ? Cizgi.muted : Cizgi.faint)
                Text(title)
                    .font(Cizgi.serif(22, relativeTo: .title2))
                    .foregroundStyle(onInk ? Cizgi.paper : Cizgi.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(onInk ? Cizgi.muted : Cizgi.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Cizgi.accent)
                .frame(width: 48, height: 48)
                .background(Cizgi.accentSoft, in: Circle())
        }
        .padding(Cizgi.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(onInk ? Cizgi.ink : Cizgi.surface)
        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                .stroke(onInk ? .clear : Cizgi.hairline, lineWidth: 1)
        )
    }
}

/// Numaralı bölüm başlığı — Egzersiz'de bölümleri birbirinden ayıran şey.
struct CizgiSectionTitle: View {
    let title: String
    var index: Int?
    var subtitle: String?
    var trailing: String?

    init(_ title: String, index: Int? = nil, subtitle: String? = nil, trailing: String? = nil) {
        self.title = title
        self.index = index
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Cizgi.Space.sm) {
                if let index {
                    Text(String(format: "%02d", index))
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(Cizgi.accent)
                }
                Text(title).font(.headline).foregroundStyle(Cizgi.ink)
                Rectangle().fill(Cizgi.hairline).frame(height: 1)
                if let trailing {
                    Text(trailing)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Cizgi.accent)
                        .fixedSize()
                }
            }
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(Cizgi.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Büyük serif sayı + ad: "Hızlı 10" gibi başlangıçlar için.
struct NumeralActionRow: View {
    let numeral: String
    let title: String
    let subtitle: String
    var tint: Color = Cizgi.accent
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Cizgi.Space.lg) {
                Text(numeral)
                    .font(Cizgi.serif(isProminent ? 32 : 22, relativeTo: .title))
                    .foregroundStyle(isProminent ? Cizgi.surface : tint)
                    .frame(minWidth: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isProminent ? Cizgi.surface : Cizgi.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isProminent ? Cizgi.surface.opacity(0.8) : Cizgi.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isProminent ? Cizgi.surface : Cizgi.hairline)
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
            .background(isProminent ? tint : Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                    .stroke(isProminent ? .clear : Cizgi.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SelectableChip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isSelected ? Cizgi.surface : Cizgi.ink)
            .padding(.horizontal, Cizgi.Space.sm)
            .padding(.vertical, Cizgi.Space.xs)
            .background(isSelected ? Cizgi.accent : Cizgi.surface, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? .clear : Cizgi.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ChipFlowRow<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: Cizgi.Space.xs)],
            alignment: .leading,
            spacing: Cizgi.Space.xs
        ) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

struct RingGauge: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(Cizgi.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Ders dağılım şeridi — Bilgilerim'in tepesinde, dokuz rengin tek satırda
/// okunduğu yer.
struct SubjectDistributionBar: View {
    /// (ders, kart sayısı) — sıfır olanlar atlanır.
    let counts: [(CizgiSubject, Int)]
    /// Yaya oturmayan kartlar (serbest metin ders adı, kavram paketinden gelen
    /// tanınmayan ad). Sıfırdan büyükse nötr bir dilim olarak çizilir.
    ///
    /// Varsayılanı 0 olduğu için tasarımın verdiği çağrı biçimi aynen derlenir.
    /// Var olma sebebi: bu kartları saymadan atlamak şeridin *oranlarını*
    /// bozar — ekran sağlıklı görünürken yanlış bir deste anlatır, ki bu
    /// projenin tam olarak kovaladığı sessiz hata sınıfı.
    var other: Int = 0
    var height: CGFloat = 9

    private var total: Int { max(1, counts.reduce(other) { $0 + $1.1 }) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(counts.filter { $0.1 > 0 }, id: \.0) { subject, count in
                    subject.color
                        .frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                }
                if other > 0 {
                    Cizgi.hairline
                        .frame(width: geo.size.width * CGFloat(other) / CGFloat(total))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

// MARK: - Butonlar

/// Amber halo kalktı; metin `surface`.
struct CizgiPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Cizgi.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Cizgi.surface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Cizgi.Space.lg)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CizgiSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Cizgi.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Cizgi.Space.md)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                    .stroke(Cizgi.hairline, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Kart tipi işaretleri
//
// Eski rozet yalnız bir isimdi. Yeni işaret sorunun *biçimini* çiziyor.

struct CardTypeMark: View {
    let type: CardType
    var size: CGFloat = 19
    var tint: Color = Cizgi.accent

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let lw = max(1.3, w * 0.085)
            var stroke = Path()

            switch type {
            case .directRecall:
                stroke.addEllipse(in: .init(x: lw, y: lw, width: w - lw * 2, height: h - lw * 2))
                ctx.stroke(stroke, with: .color(tint), lineWidth: lw)
                var dot = Path()
                dot.addEllipse(in: .init(x: w * 0.355, y: h * 0.355, width: w * 0.29, height: h * 0.29))
                ctx.fill(dot, with: .color(tint))

            case .cloze:
                stroke.move(to: .init(x: 0, y: h * 0.66))
                stroke.addLine(to: .init(x: w * 0.24, y: h * 0.66))
                stroke.move(to: .init(x: w * 0.76, y: h * 0.66))
                stroke.addLine(to: .init(x: w, y: h * 0.66))
                ctx.stroke(stroke, with: .color(tint), lineWidth: lw)
                let box = Path(roundedRect: .init(x: w * 0.32, y: h * 0.3, width: w * 0.36, height: h * 0.38),
                               cornerRadius: lw)
                ctx.stroke(box, with: .color(tint),
                           style: StrokeStyle(lineWidth: lw, dash: [w * 0.1, w * 0.09]))

            case .mechanism:
                stroke.move(to: .init(x: w * 0.14, y: h * 0.34))
                stroke.addLine(to: .init(x: w * 0.58, y: h * 0.34))
                stroke.addQuadCurve(to: .init(x: w * 0.58, y: h * 0.7),
                                    control: .init(x: w * 0.94, y: h * 0.52))
                stroke.addLine(to: .init(x: w * 0.36, y: h * 0.7))
                stroke.move(to: .init(x: w * 0.5, y: h * 0.56))
                stroke.addLine(to: .init(x: w * 0.34, y: h * 0.7))
                stroke.addLine(to: .init(x: w * 0.5, y: h * 0.85))
                ctx.stroke(stroke, with: .color(tint),
                           style: .init(lineWidth: lw, lineCap: .round, lineJoin: .round))
                var dot = Path()
                dot.addEllipse(in: .init(x: w * 0.06, y: h * 0.26, width: w * 0.16, height: w * 0.16))
                ctx.fill(dot, with: .color(tint))

            case .distinction:
                stroke.move(to: .init(x: w * 0.5, y: h * 0.08))
                stroke.addLine(to: .init(x: w * 0.5, y: h * 0.92))
                stroke.move(to: .init(x: w * 0.3, y: h * 0.3))
                stroke.addLine(to: .init(x: w * 0.1, y: h * 0.5))
                stroke.addLine(to: .init(x: w * 0.3, y: h * 0.7))
                stroke.move(to: .init(x: w * 0.7, y: h * 0.3))
                stroke.addLine(to: .init(x: w * 0.9, y: h * 0.5))
                stroke.addLine(to: .init(x: w * 0.7, y: h * 0.7))
                ctx.stroke(stroke, with: .color(tint),
                           style: .init(lineWidth: lw, lineCap: .round, lineJoin: .round))

            case .exceptionTrap:
                stroke.move(to: .init(x: w * 0.5, y: h * 0.1))
                stroke.addLine(to: .init(x: w * 0.94, y: h * 0.86))
                stroke.addLine(to: .init(x: w * 0.06, y: h * 0.86))
                stroke.closeSubpath()
                stroke.move(to: .init(x: w * 0.5, y: h * 0.42))
                stroke.addLine(to: .init(x: w * 0.5, y: h * 0.62))
                ctx.stroke(stroke, with: .color(tint),
                           style: .init(lineWidth: lw, lineJoin: .round))
                var dot = Path()
                dot.addEllipse(in: .init(x: w * 0.45, y: h * 0.68, width: w * 0.1, height: w * 0.1))
                ctx.fill(dot, with: .color(tint))

            case .multipleChoice:
                for i in 0..<4 {
                    let y = h * (0.16 + 0.23 * Double(i))
                    stroke.move(to: .init(x: w * 0.36, y: y))
                    stroke.addLine(to: .init(x: w, y: y))
                }
                ctx.stroke(stroke, with: .color(tint), lineWidth: lw)
                var rings = Path()
                for i in 0..<4 where i != 2 {
                    let y = h * (0.16 + 0.23 * Double(i))
                    rings.addEllipse(in: .init(x: w * 0.06, y: y - w * 0.06,
                                               width: w * 0.12, height: w * 0.12))
                }
                ctx.stroke(rings, with: .color(tint), lineWidth: lw * 0.8)
                var filled = Path()
                let y = h * (0.16 + 0.23 * 2)
                filled.addEllipse(in: .init(x: w * 0.02, y: y - w * 0.1,
                                            width: w * 0.2, height: w * 0.2))
                ctx.fill(filled, with: .color(tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// İşaret + etiket. Renk işarette, ad mürekkepte.
struct CardTypeBadge: View {
    let type: CardType
    var subject: CizgiSubject?
    var body: some View {
        HStack(spacing: Cizgi.Space.sm) {
            CardTypeMark(type: type, tint: subject?.color ?? Cizgi.accent)
            Text(type.displayName)
                .font(.caption.weight(.bold))
                .foregroundStyle(Cizgi.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(type.displayName)
    }
}

extension CardType {
    var displayName: String {
        switch self {
        case .directRecall: return "Hatırlama"
        case .cloze: return "Boşluk"
        case .mechanism: return "Mekanizma"
        case .distinction: return "Ayırt etme"
        case .exceptionTrap: return "İstisna"
        case .multipleChoice: return "Beş şık"
        }
    }

    /// Ne tür bir soru olduğunu bir cümlede söyler — kılavuzdaki metinler.
    var explainer: String {
        switch self {
        case .directRecall: return "Tek bir olgu, tam merkezde."
        case .cloze: return "Cümle duruyor, bir parçası çıkarılmış."
        case .mechanism: return "Bir zincir: neden buradan başlar, oraya varır."
        case .distinction: return "İki şey karışıyor; hangi eksende ayrıldıkları sorulur."
        case .exceptionTrap: return "Kural işliyor — bir yer hariç."
        case .multipleChoice: return "Biri doğru, dördü nedenli yanlış."
        }
    }

    /// SF Symbols'a hâlâ ihtiyaç duyan yerler (filtre menüsü, VoiceOver) için.
    var icon: String {
        switch self {
        case .directRecall: return "circle.circle"
        case .cloze: return "rectangle.dashed"
        case .mechanism: return "arrow.triangle.turn.up.right.circle"
        case .distinction: return "arrow.left.and.right"
        case .exceptionTrap: return "exclamationmark.triangle"
        case .multipleChoice: return "list.bullet.circle"
        }
    }
}

// MARK: - Filtre / derecelendirme etiketleri (mevcut davranış korunuyor)

extension CardStateFilter {
    var displayName: String {
        switch self {
        case .unstudied: return "Hiç çalışılmamış"
        case .due: return "Vadesi gelmiş"
        case .needsReview: return "Gözden geçir"
        }
    }
    var icon: String {
        switch self {
        case .unstudied: return "circle.dashed"
        case .due: return "clock.badge.exclamationmark"
        case .needsReview: return "exclamationmark.triangle.fill"
        }
    }
}

extension CardRecency {
    var displayName: String {
        switch self {
        case .all: return "Tümü"
        case .last7Days: return "Son 7 gün"
        case .last30Days: return "Son 30 gün"
        }
    }
}

extension FilterDimension {
    var label: String {
        switch self {
        case .subject(let name): return name
        case .topic(let filter):
            switch filter {
            case .all: return "Tüm konular"
            case .none: return "Konusuz"
            case .topic(let name): return name
            }
        case .cardType(let type): return type.displayName
        case .state(let state): return state.displayName
        case .recency(let recency): return recency.displayName
        case .fesOnly: return "FES"
        }
    }
    var icon: String {
        switch self {
        case .subject: return "book"
        case .topic(let filter): return filter == .none ? "tag.slash" : "tag"
        case .cardType(let type): return type.icon
        case .state(let state): return state.icon
        case .recency: return "calendar"
        case .fesOnly: return "flame.fill"
        }
    }
}

/// "Kolay" artık vurgu renginde değil — mürekkep. Vurgu bir eylem daveti;
/// burada dört seçenek eşit ağırlıkta.
extension ReviewRating {
    var tint: Color {
        switch self {
        case .again: return Cizgi.danger
        case .hard: return Cizgi.warning
        case .good: return Cizgi.success
        case .easy: return Cizgi.ink
        }
    }
}
