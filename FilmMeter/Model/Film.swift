import Foundation

enum FilmKind: String, Codable, CaseIterable, Identifiable {
    case colorNegative = "Color negative"
    case bwNegative = "B&W negative"
    case slide = "Slide"
    var id: String { rawValue }
}

/// One published reciprocity point: at `metered` seconds, add `addStops`.
/// `corrected` is the adjusted time when the data sheet gives one.
struct RecipPoint: Codable, Hashable {
    var metered: Double
    var addStops: Double
    var corrected: Double?
}

struct ReciprocityRule: Codable, Hashable {
    enum Kind: String, Codable { case power, table }

    var kind: Kind
    /// Exposures at or below this time need no correction.
    var noCorrectionUpTo: Double
    /// Power rule: Tc = base * (Tm / base)^exponent, with base = noCorrectionUpTo.
    var exponent: Double = 1.0
    var points: [RecipPoint] = []
    /// True when the power rule is our estimate rather than the manufacturer's formula.
    var powerIsEstimate: Bool = false
    var notRecommendedBeyond: Double? = nil
    var note: String = ""

    static func power(_ p: Double, from start: Double = 1, estimate: Bool, note: String) -> ReciprocityRule {
        ReciprocityRule(kind: .power, noCorrectionUpTo: start, exponent: p, powerIsEstimate: estimate, note: note)
    }

    static func table(_ pts: [RecipPoint], noneUpTo: Double, notRecommendedBeyond: Double? = nil, note: String) -> ReciprocityRule {
        ReciprocityRule(kind: .table, noCorrectionUpTo: noneUpTo, points: pts.sorted { $0.metered < $1.metered },
                        notRecommendedBeyond: notRecommendedBeyond, note: note)
    }
}

struct ReciprocityResult: Hashable {
    var metered: Double
    var corrected: Double
    var isEstimate: Bool
    var notRecommended: Bool
    var note: String
    var needsCorrection: Bool { corrected > metered * 1.04 }
}

extension ReciprocityRule {
    func correct(_ t: Double) -> ReciprocityResult {
        let notRec = notRecommendedBeyond.map { t > $0 } ?? false
        guard t > noCorrectionUpTo else {
            return ReciprocityResult(metered: t, corrected: t, isEstimate: false, notRecommended: false, note: note)
        }
        switch kind {
        case .power:
            let base = max(noCorrectionUpTo, 1e-6)
            let tc = base * pow(t / base, exponent)
            return ReciprocityResult(metered: t, corrected: tc, isEstimate: powerIsEstimate, notRecommended: notRec, note: note)
        case .table:
            // Interpolate log2(corrected) against log2(metered), starting from the no-correction limit.
            var nodes: [(Double, Double)] = [(log2(noCorrectionUpTo), log2(noCorrectionUpTo))]
            for p in points {
                let c = p.corrected ?? p.metered * pow(2, p.addStops)
                nodes.append((log2(p.metered), log2(c)))
            }
            let x = log2(t)
            var y: Double
            var estimate = false
            if nodes.count == 1 {
                y = x
            } else if x >= nodes[nodes.count - 1].0 {
                let a = nodes[nodes.count - 2], b = nodes[nodes.count - 1]
                let slope = (b.1 - a.1) / max(b.0 - a.0, 1e-6)
                y = b.1 + (x - b.0) * slope
                estimate = x > b.0 + 1e-6
            } else {
                y = x
                for i in 1..<nodes.count where x <= nodes[i].0 {
                    let a = nodes[i - 1], b = nodes[i]
                    let f = (x - a.0) / max(b.0 - a.0, 1e-6)
                    y = a.1 + f * (b.1 - a.1)
                    break
                }
            }
            return ReciprocityResult(metered: t, corrected: max(t, pow(2, y)), isEstimate: estimate, notRecommended: notRec, note: note)
        }
    }

    /// Effective (metered-equivalent) exposure time actually delivered when the shutter is open for `t`.
    func effectiveTime(forActual t: Double) -> Double {
        guard t > noCorrectionUpTo else { return t }
        var lo = noCorrectionUpTo, hi = t
        for _ in 0..<40 {
            let mid = sqrt(lo * hi)
            if correct(mid).corrected > t { hi = mid } else { lo = mid }
        }
        return sqrt(lo * hi)
    }
}

struct FilmStock: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: FilmKind
    var iso: Double
    /// Stops below middle grey where shadow detail runs out (negative number).
    var shadowLimit: Double
    /// Stops above middle grey where highlight detail runs out.
    var highlightLimit: Double
    /// Visible grain on 35mm at phone-screen size, 1.0 roughly Tri-X.
    var grain: Double
    var saturation: Double = 1
    var contrast: Double = 1
    /// Positive warms, negative cools.
    var warmth: Double = 0
    /// Positive adds magenta, negative adds green.
    var tint: Double = 0
    /// Approximate spectral response for B&W stocks (R, G, B weights on linear light).
    var bwWeights: [Double] = [0.30, 0.56, 0.14]
    var reciprocity: ReciprocityRule
    var dataSheet: String
    var sheetNote: String = ""
}

enum StockLibrary {
    static let kodakColorNote = "Kodak: no correction from 1/10,000 s to 1 s. Longer exposures: the sheet says to test; the 1.33 power rule is an estimate."

    static let all: [FilmStock] = [
        // Kodak color negative (grain from Print Grain Index, 135 at 4x6)
        FilmStock(id: "portra160", name: "Kodak Portra 160", kind: .colorNegative, iso: 160, shadowLimit: -3.0, highlightLimit: 8.5,
                  grain: 0.50, saturation: 0.93, contrast: 0.95,
                  reciprocity: .power(1.33, estimate: true, note: kodakColorNote),
                  dataSheet: "Kodak E-4051 (Jan 2025)", sheetNote: "Print Grain Index 28."),
        FilmStock(id: "portra400", name: "Kodak Portra 400", kind: .colorNegative, iso: 400, shadowLimit: -3.5, highlightLimit: 9.0,
                  grain: 0.65,
                  reciprocity: .power(1.33, estimate: true, note: kodakColorNote),
                  dataSheet: "Kodak E-4050 (Jan 2025)", sheetNote: "Print Grain Index 37."),
        FilmStock(id: "portra800", name: "Kodak Portra 800", kind: .colorNegative, iso: 800, shadowLimit: -3.7, highlightLimit: 8.0,
                  grain: 0.85, saturation: 1.04, contrast: 1.03, warmth: 0.2,
                  reciprocity: .power(1.33, estimate: true, note: kodakColorNote),
                  dataSheet: "Kodak E-4040 (Jan 2025)", sheetNote: "Print Grain Index 48. Kodak cites best-in-class underexposure latitude."),
        FilmStock(id: "ektar100", name: "Kodak Ektar 100", kind: .colorNegative, iso: 100, shadowLimit: -2.5, highlightLimit: 7.0,
                  grain: 0.42, saturation: 1.25, contrast: 1.12,
                  reciprocity: .power(1.33, estimate: true, note: kodakColorNote),
                  dataSheet: "Kodak E-4046 (Jan 2025)", sheetNote: "Print Grain Index under 25."),
        FilmStock(id: "gold200", name: "Kodak Gold 200", kind: .colorNegative, iso: 200, shadowLimit: -2.7, highlightLimit: 7.0,
                  grain: 0.80, saturation: 1.10, contrast: 1.05, warmth: 0.45,
                  reciprocity: .power(1.33, estimate: true, note: kodakColorNote),
                  dataSheet: "Kodak E-7022 (Jun 2023)", sheetNote: "Print Grain Index 44. Kodak: prints well from 2 stops under to 3 stops over."),
        FilmStock(id: "ultramax400", name: "Kodak UltraMax 400", kind: .colorNegative, iso: 400, shadowLimit: -3.0, highlightLimit: 7.0,
                  grain: 0.85, saturation: 1.10, contrast: 1.07, warmth: 0.3,
                  reciprocity: .power(1.33, estimate: true, note: kodakColorNote + " UltraMax may also need filtration."),
                  dataSheet: "Kodak E-7023 (Feb 2016)", sheetNote: "Print Grain Index 46."),
        FilmStock(id: "colorplus200", name: "Kodak ColorPlus / Kodacolor 200", kind: .colorNegative, iso: 200, shadowLimit: -2.5, highlightLimit: 6.5,
                  grain: 0.90, saturation: 1.05, contrast: 1.0, warmth: 0.5,
                  reciprocity: .power(1.33, estimate: true, note: "No Kodak data sheet exists; reciprocity and latitude are estimates."),
                  dataSheet: "None published", sheetNote: "Values are estimates."),
        FilmStock(id: "fuji200", name: "Fujifilm 200", kind: .colorNegative, iso: 200, shadowLimit: -2.7, highlightLimit: 7.0,
                  grain: 0.80, saturation: 1.05, contrast: 1.02, warmth: 0.1, tint: -0.2,
                  reciprocity: .power(1.33, estimate: true, note: "Fujifilm publishes no reciprocity data; estimate."),
                  dataSheet: "Fujifilm AF3-0261E (Feb 2022)", sheetNote: "No grain figure published."),
        FilmStock(id: "cinestill800t", name: "CineStill 800T", kind: .colorNegative, iso: 800, shadowLimit: -3.0, highlightLimit: 7.0,
                  grain: 0.80, saturation: 1.05, contrast: 1.05, warmth: -1.2,
                  reciprocity: .power(1.3, estimate: true, note: "CineStill's general guidance: Tc ≈ Tm^1.3 beyond 1 s, and bracket."),
                  dataSheet: "CineStill help center (no data sheet)", sheetNote: "Tungsten balanced: renders cool in daylight unless you add an 85B."),
        FilmStock(id: "cinestill400d", name: "CineStill 400D", kind: .colorNegative, iso: 400, shadowLimit: -3.3, highlightLimit: 8.0,
                  grain: 0.60, saturation: 1.05, contrast: 1.0, warmth: 0.15,
                  reciprocity: .power(1.3, estimate: true, note: "CineStill's general guidance: Tc ≈ Tm^1.3 beyond 1 s, and bracket."),
                  dataSheet: "CineStill help center (no data sheet)", sheetNote: "CineStill: usable from EI 200 to 800 with normal processing."),
        // B&W
        FilmStock(id: "hp5", name: "Ilford HP5 Plus", kind: .bwNegative, iso: 400, shadowLimit: -3.5, highlightLimit: 7.0,
                  grain: 0.90, contrast: 1.0, bwWeights: [0.27, 0.55, 0.18],
                  reciprocity: .power(1.31, estimate: false, note: "Ilford: Tc = Tm^1.31 beyond 1 s."),
                  dataSheet: "Ilford HP5 Plus (Nov 2018)"),
        FilmStock(id: "fp4", name: "Ilford FP4 Plus", kind: .bwNegative, iso: 125, shadowLimit: -3.0, highlightLimit: 7.5,
                  grain: 0.60, contrast: 1.05, bwWeights: [0.28, 0.55, 0.17],
                  reciprocity: .power(1.26, estimate: false, note: "Ilford: Tc = Tm^1.26 beyond 1 s."),
                  dataSheet: "Ilford FP4 Plus (Nov 2018)", sheetNote: "Ilford: usable when overexposed up to 6 stops or underexposed 2."),
        FilmStock(id: "delta100", name: "Ilford Delta 100", kind: .bwNegative, iso: 100, shadowLimit: -3.0, highlightLimit: 7.0,
                  grain: 0.42, contrast: 1.08, bwWeights: [0.30, 0.55, 0.15],
                  reciprocity: .power(1.26, estimate: false, note: "Ilford: Tc = Tm^1.26 beyond 1 s."),
                  dataSheet: "Ilford Delta 100 (Apr 2023)"),
        FilmStock(id: "delta400", name: "Ilford Delta 400", kind: .bwNegative, iso: 400, shadowLimit: -3.2, highlightLimit: 7.0,
                  grain: 0.65, contrast: 1.0, bwWeights: [0.29, 0.54, 0.17],
                  reciprocity: .power(1.41, estimate: false, note: "Ilford: Tc = Tm^1.41 beyond 1 s."),
                  dataSheet: "Ilford Delta 400 (Nov 2018)"),
        FilmStock(id: "delta3200", name: "Ilford Delta 3200", kind: .bwNegative, iso: 3200, shadowLimit: -2.3, highlightLimit: 6.0,
                  grain: 1.30, contrast: 0.95, bwWeights: [0.30, 0.52, 0.18],
                  reciprocity: .power(1.33, estimate: false, note: "Ilford: Tc = Tm^1.33 beyond 1 s."),
                  dataSheet: "Ilford Delta 3200 (Jun 2025)", sheetNote: "Measured speed ISO 1000; EI 3200 is already a push."),
        FilmStock(id: "xp2", name: "Ilford XP2 Super", kind: .bwNegative, iso: 400, shadowLimit: -3.0, highlightLimit: 9.0,
                  grain: 0.55, contrast: 0.9, bwWeights: [0.28, 0.56, 0.16],
                  reciprocity: .power(1.31, estimate: false, note: "Ilford: Tc = Tm^1.31 beyond 1 s."),
                  dataSheet: "Ilford XP2 Super (Nov 2018)", sheetNote: "Ilford: exposable from EI 50 to 800."),
        FilmStock(id: "panf", name: "Ilford Pan F Plus", kind: .bwNegative, iso: 50, shadowLimit: -2.5, highlightLimit: 6.0,
                  grain: 0.35, contrast: 1.15, bwWeights: [0.30, 0.55, 0.15],
                  reciprocity: .power(1.33, estimate: false, note: "Ilford: Tc = Tm^1.33 beyond 1 s."),
                  dataSheet: "Ilford Pan F Plus (B26)"),
        FilmStock(id: "trix", name: "Kodak Tri-X 400", kind: .bwNegative, iso: 400, shadowLimit: -3.5, highlightLimit: 7.0,
                  grain: 0.90, contrast: 1.05, bwWeights: [0.24, 0.52, 0.24],
                  reciprocity: .table([RecipPoint(metered: 1, addStops: 1, corrected: 2),
                                       RecipPoint(metered: 10, addStops: 2, corrected: 50),
                                       RecipPoint(metered: 100, addStops: 3, corrected: 1200)],
                                      noneUpTo: 0.1, note: "Kodak F-4017: also cut development 10% at 1 s, 20% at 10 s, 30% at 100 s."),
                  dataSheet: "Kodak F-4017 (Oct 2021)", sheetNote: "RMS granularity 17."),
        FilmStock(id: "tmax100", name: "Kodak T-Max 100", kind: .bwNegative, iso: 100, shadowLimit: -3.0, highlightLimit: 7.0,
                  grain: 0.45, contrast: 1.1, bwWeights: [0.26, 0.52, 0.22],
                  reciprocity: .table([RecipPoint(metered: 1, addStops: 1.0 / 3.0, corrected: nil),
                                       RecipPoint(metered: 10, addStops: 0.5, corrected: 15),
                                       RecipPoint(metered: 100, addStops: 1, corrected: 200)],
                                      noneUpTo: 0.1, note: "Kodak F-4016: at 1 s the sheet says open the aperture ⅓ stop instead."),
                  dataSheet: "Kodak F-4016 (Jun 2018)", sheetNote: "RMS granularity 8."),
        FilmStock(id: "tmax400", name: "Kodak T-Max 400", kind: .bwNegative, iso: 400, shadowLimit: -3.5, highlightLimit: 8.0,
                  grain: 0.55, contrast: 1.05, bwWeights: [0.26, 0.52, 0.22],
                  reciprocity: .table([RecipPoint(metered: 10, addStops: 1.0 / 3.0, corrected: nil),
                                       RecipPoint(metered: 100, addStops: 1.5, corrected: 300)],
                                      noneUpTo: 1, note: "Kodak F-4043: at 10 s the sheet says open the aperture ⅓ stop instead."),
                  dataSheet: "Kodak F-4043 (Feb 2016)", sheetNote: "RMS granularity 10."),
        // Slide
        FilmStock(id: "e100", name: "Kodak Ektachrome E100", kind: .slide, iso: 100, shadowLimit: -2.5, highlightLimit: 2.3,
                  grain: 0.33, saturation: 1.1, contrast: 1.15,
                  reciprocity: .power(1.33, from: 10, estimate: true, note: "Kodak E-4000: no correction to 10 s; at 120 s add CC10R. Longer times are estimates."),
                  dataSheet: "Kodak E-4000 (Aug 2018)", sheetNote: "RMS granularity 8."),
        FilmStock(id: "velvia50", name: "Fujifilm Velvia 50", kind: .slide, iso: 50, shadowLimit: -2.0, highlightLimit: 2.0,
                  grain: 0.33, saturation: 1.45, contrast: 1.35, warmth: 0.2, tint: 0.2,
                  reciprocity: .table([RecipPoint(metered: 4, addStops: 1.0 / 3.0, corrected: nil),
                                       RecipPoint(metered: 8, addStops: 0.5, corrected: nil),
                                       RecipPoint(metered: 16, addStops: 2.0 / 3.0, corrected: nil),
                                       RecipPoint(metered: 32, addStops: 1, corrected: nil)],
                                      noneUpTo: 1, notRecommendedBeyond: 32,
                                      note: "Fujifilm: add 5M, 7.5M, 10M, 12.5M filtration at 4, 8, 16, 32 s. 64 s not recommended."),
                  dataSheet: "Fujifilm AF3-0221E2", sheetNote: "RMS granularity 9."),
        FilmStock(id: "velvia100", name: "Fujifilm Velvia 100", kind: .slide, iso: 100, shadowLimit: -2.0, highlightLimit: 2.0,
                  grain: 0.30, saturation: 1.35, contrast: 1.3, tint: 0.1,
                  reciprocity: .table([RecipPoint(metered: 120, addStops: 1.0 / 3.0, corrected: nil),
                                       RecipPoint(metered: 240, addStops: 0.5, corrected: nil),
                                       RecipPoint(metered: 480, addStops: 2.0 / 3.0, corrected: nil)],
                                      noneUpTo: 60, note: "Fujifilm: add 2.5M filtration beyond 1 minute."),
                  dataSheet: "Fujifilm AF3-202E", sheetNote: "RMS granularity 8."),
        FilmStock(id: "provia100f", name: "Fujifilm Provia 100F", kind: .slide, iso: 100, shadowLimit: -2.5, highlightLimit: 2.3,
                  grain: 0.30, saturation: 1.15, contrast: 1.2,
                  reciprocity: .table([RecipPoint(metered: 240, addStops: 1.0 / 3.0, corrected: nil)],
                                      noneUpTo: 128, notRecommendedBeyond: 479,
                                      note: "Fujifilm: none to 128 s; 4 min +⅓ with 2.5G; 8 min not recommended."),
                  dataSheet: "Fujifilm AF3-036E", sheetNote: "RMS granularity 8. Fujifilm: tolerance −½ to +2 stops."),
    ]

    static func stock(_ id: String?) -> FilmStock? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
