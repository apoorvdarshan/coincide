import Foundation

/// Hosts reduced to the site they belong to, the way browsers and password managers group them: `www.example.co.uk`
/// and `login.example.co.uk` are both the site `example.co.uk`. A compact list of multi-label public suffixes stands
/// in for the full Public Suffix List; hosts under a suffix it doesn't know fall back to their last two labels, which
/// errs toward a narrower site, never a broader one shared with strangers.
public nonisolated enum WebDomain {
    /// Suffixes under which every label is a separate owner, so `a.github.io` and `b.github.io` never share a site.
    static let multiLabelSuffixes: Set<String> = [
        // Country-code second levels.
        "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp", "ad.jp", "ed.jp", "lg.jp",
        "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr", "re.kr",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "edu.in", "gov.in", "res.in",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg",
        "com.my", "net.my", "org.my", "edu.my", "gov.my",
        "co.id", "or.id", "ac.id", "go.id", "web.id", "my.id",
        "co.za", "org.za", "net.za", "gov.za", "ac.za",
        "com.mx", "org.mx", "gob.mx", "edu.mx", "net.mx",
        "com.ar", "org.ar", "net.ar", "gob.ar", "edu.ar",
        "com.tr", "org.tr", "net.tr", "gov.tr", "edu.tr", "gen.tr",
        "com.ua", "org.ua", "net.ua", "gov.ua", "in.ua",
        "com.pl", "net.pl", "org.pl", "gov.pl", "edu.pl",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn",
        "co.th", "in.th", "ac.th", "go.th", "or.th",
        "com.ph", "net.ph", "org.ph", "gov.ph", "edu.ph",
        "com.pk", "net.pk", "org.pk", "gov.pk", "edu.pk",
        "com.sa", "net.sa", "org.sa", "gov.sa", "edu.sa",
        "com.eg", "org.eg", "net.eg", "gov.eg", "edu.eg",
        "com.co", "net.co", "org.co", "gov.co", "edu.co",
        "com.pe", "org.pe", "net.pe", "gob.pe", "edu.pe",
        "com.ru", "org.ru", "net.ru", "msk.ru", "spb.ru",
        "co.at", "or.at", "ac.at", "gv.at",
        "com.es", "org.es", "nom.es", "gob.es", "edu.es",
        "com.pt", "org.pt", "gov.pt", "edu.pt",
        "com.gr", "org.gr", "net.gr", "gov.gr", "edu.gr",
        "co.ke", "or.ke", "ac.ke", "go.ke",
        "com.ng", "org.ng", "gov.ng", "edu.ng",
        // Hosting platforms that give every customer a subdomain.
        "github.io", "githubusercontent.com", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app",
        "herokuapp.com", "azurewebsites.net", "cloudfront.net", "appspot.com", "web.app", "firebaseapp.com",
        "blogspot.com", "fly.dev", "onrender.com", "glitch.me", "repl.co", "ngrok.io", "ngrok-free.app",
        "s3.amazonaws.com", "amplifyapp.com", "surge.sh", "deno.dev", "wixsite.com", "myshopify.com",
    ]

    /// The site of `host`: the label before its public suffix, with that suffix. Nil for an IP address, `localhost`
    /// or a single label, which are their own sites and only ever match themselves (`isSameSite`).
    public static func site(of host: String) -> String? {
        let host = normalize(host)
        guard !host.isEmpty, !isIPAddress(host), host != "localhost", !host.hasSuffix(".localhost") else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        // The longest known suffix wins, so `a.s3.amazonaws.com` stays apart from `b.s3.amazonaws.com`.
        for take in stride(from: min(labels.count - 1, 3), through: 2, by: -1) {
            let suffix = labels.suffix(take).joined(separator: ".")
            if multiLabelSuffixes.contains(suffix) { return labels.suffix(take + 1).joined(separator: ".") }
        }
        if labels.count == 2, multiLabelSuffixes.contains(host) { return nil }
        return labels.suffix(2).joined(separator: ".")
    }

    /// The site a host groups under for display and import filters: its site, or the host itself when it has none.
    public static func siteOrHost(_ host: String) -> String { site(of: host) ?? normalize(host) }

    /// Lowercased, without a cookie domain's leading dot, a trailing root dot or IPv6 brackets.
    public static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        return value
    }

    public static func isIPAddress(_ host: String) -> Bool {
        let value = normalize(host)
        if value.contains(":") { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) }
    }

    /// Whether `host` is `domain` or one of its subdomains, on a label boundary (`evil-example.com` is not under
    /// `example.com`).
    public static func host(_ host: String, isWithin domain: String) -> Bool {
        let host = normalize(host), domain = normalize(domain)
        guard !host.isEmpty, !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
