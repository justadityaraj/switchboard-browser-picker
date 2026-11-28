import Foundation
import CoreGraphics
import SwitchboardCore

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if !condition {
        failures += 1
        print("FAIL: \(name)")
    }
}

let chrome = Target(browser: "com.google.Chrome")
let work = Target(browser: "com.google.Chrome", profile: "Profile 1")
let safari = Target(browser: "com.apple.Safari")

let hostRule = Rule(hosts: ["google.com"], open: chrome)
check(hostRule.matches(url: URL(string: "https://meet.google.com/abc")!, sourceApp: nil), "subdomain matches host rule")
check(hostRule.matches(url: URL(string: "https://GOOGLE.com")!, sourceApp: nil), "host rule is case-insensitive")
check(!hostRule.matches(url: URL(string: "https://notgoogle.com")!, sourceApp: nil), "suffix without dot does not match")

let patternRule = Rule(urlPattern: "github\\.com/acme-", open: work)
check(patternRule.matches(url: URL(string: "https://github.com/acme-corp/app")!, sourceApp: nil), "url pattern matches")
check(!patternRule.matches(url: URL(string: "https://github.com/morluto/rea")!, sourceApp: nil), "url pattern rejects other paths")

let slackRule = Rule(hosts: ["zoom.us"], sourceApps: ["com.tinyspeck.slackmacgap"], open: safari)
check(slackRule.matches(url: URL(string: "https://zoom.us/j/1")!, sourceApp: "com.tinyspeck.slackmacgap"), "all conditions match")
check(!slackRule.matches(url: URL(string: "https://zoom.us/j/1")!, sourceApp: nil), "missing source app fails source rule")
check(!Rule(open: chrome).matches(url: URL(string: "https://x.com")!, sourceApp: nil), "rule without conditions never matches")

let config = Config(defaultTarget: safari, rules: [patternRule, hostRule])
check(config.target(for: URL(string: "https://github.com/acme-corp/app")!, sourceApp: nil) == work, "first matching rule wins")
check(config.target(for: URL(string: "https://example.com")!, sourceApp: nil) == nil, "no rule leaves target to the default")

let json = #"{"rules":[{"hosts":["notion.so"],"open":{"browser":"com.brave.Browser","profile":"Default","private":true}}]}"#
let decoded = try! JSONDecoder().decode(Config.self, from: Data(json.utf8))
check(decoded.rules.first?.open == Target(browser: "com.brave.Browser", profile: "Default", privateWindow: true), "config decodes with missing keys")
check(decoded.hiddenBrowsers.isEmpty && decoded.defaultTarget == nil, "missing keys fall back to empty")

check(BrowserFamily.launchFlags(for: Target(browser: "com.google.Chrome", profile: "Profile 2", privateWindow: true)) == ["--profile-directory=Profile 2", "--incognito"], "chromium flags")
check(BrowserFamily.launchFlags(for: Target(browser: "org.mozilla.firefox", privateWindow: true)) == ["--private-window"], "firefox private flag")
check(BrowserFamily.launchFlags(for: Target(browser: "com.apple.Safari", privateWindow: true)).isEmpty, "safari takes no flags")

let localState = #"{"profile":{"info_cache":{"Profile 10":{"name":"Side Project"},"Profile 2":{"name":"Work"},"Default":{"name":"Personal"}}}}"#
let profiles = BrowserFamily.chromiumProfiles(localState: Data(localState.utf8))
check(profiles.map(\.directory) == ["Default", "Profile 2", "Profile 10"], "profiles sort Default first then naturally")
check(profiles.map(\.name) == ["Personal", "Work", "Side Project"], "profile display names")
check(BrowserFamily.chromiumProfiles(localState: Data("nope".utf8)).isEmpty, "bad Local State yields no profiles")

check(Rule.normalizedHost("https://www.GitHub.com/morluto/rea") == "github.com", "pasted URL normalizes to host")
check(Rule.normalizedHost(" notion.so/page ") == "notion.so", "bare host with path normalizes")
check(Rule.normalizedHost("   ") == nil, "blank host is rejected")

var remembering = Config(rules: [hostRule, Rule(hosts: ["github.com"], open: safari)])
remembering.remember(host: "www.github.com", target: work)
check(remembering.rules.count == 2, "remembering replaces the plain rule for that host")
check(remembering.rules.first == Rule(hosts: ["github.com"], open: work), "remembered rule goes first")

func cleaned(_ string: String) -> String { LinkCleaner.clean(URL(string: string)!).absoluteString }
check(cleaned("https://example.com/a?utm_source=x&id=7&fbclid=abc") == "https://example.com/a?id=7", "tracking params removed, real ones kept")
check(cleaned("https://example.com/a?utm_medium=email&gclid=1") == "https://example.com/a", "query dropped when only tracking remains")
check(cleaned("https://example.com/a?q=hello%20world&utm_campaign=z") == "https://example.com/a?q=hello%20world", "kept values stay percent-encoded")
check(cleaned("https://youtu.be/abc?si=TRACK&t=42") == "https://youtu.be/abc?t=42", "site-specific param removed, timestamp kept")
check(cleaned("https://example.com/a?si=keep") == "https://example.com/a?si=keep", "site-specific params only apply to their site")
check(cleaned("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fgithub.com%2Facme%3Futm_source%3Dmail&data=x") == "https://github.com/acme", "SafeLinks unwrapped then cleaned")
check(cleaned("https://www.google.com/url?q=https://example.com/page&sa=D") == "https://example.com/page", "Google redirect unwrapped")
check(cleaned("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2F&h=AT0") == "https://example.com/", "Facebook redirect unwrapped")
check(cleaned("https://www.google.com/search?q=switchboard") == "https://www.google.com/search?q=switchboard", "non-redirect Google URLs untouched")
check(cleaned("https://www.google.com/url?q=javascript:alert(1)") == "https://www.google.com/url?q=javascript:alert(1)", "non-http redirect targets are not followed")
check(cleaned("https://example.com/page#utm_source=x") == "https://example.com/page#utm_source=x", "fragments untouched")
check(try! JSONDecoder().decode(Config.self, from: Data("{}".utf8)).cleanLinks, "link cleanup defaults to on")

let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
let picker = CGSize(width: 320, height: 200)
func place(_ x: CGFloat, _ y: CGFloat, _ size: CGSize = picker, in bounds: CGRect = screen) -> CGPoint {
    PickerPlacement.origin(cursor: CGPoint(x: x, y: y), size: size, in: bounds)
}
check(place(100, 500) == CGPoint(x: 96, y: 304), "picker opens right of and below the cursor, cursor just inside")
check(place(900, 500) == CGPoint(x: 584, y: 304), "picker flips left near the right edge")
check(place(100, 50) == CGPoint(x: 96, y: 46), "picker flips up near the bottom edge")
check(place(900, 50) == CGPoint(x: 584, y: 46), "picker flips left and up in the corner")
check(place(100, 790, CGSize(width: 320, height: 900)) == CGPoint(x: 96, y: -100), "picker taller than the screen keeps its top on screen")
check(place(-100, 300, in: CGRect(x: -1440, y: 100, width: 1440, height: 900)) == CGPoint(x: -416, y: 104), "placement respects a screen left of the main one")

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All checks passed")
