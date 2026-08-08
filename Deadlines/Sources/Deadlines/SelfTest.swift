import Foundation

/// The parts that would be wrong without looking wrong.
///
/// A countdown is a confident-looking number, so every way it can be quietly
/// incorrect is worth a check: a twelve-hour timezone slip, a deadline from
/// last year presented as the next one, a conference whose next round is not
/// announced being silently dropped. Run with --selftest.
@MainActor
enum SelfTest {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }

        // --- timezones, where a silent twelve-hour error lives
        check("AoE is UTC-12", Zone.offset("AoE") == -12 * 3600,
              "Anywhere on Earth is the last place where it is still that date; "
            + "treating it as UTC loses papers")
        check("aoe is read case-insensitively", Zone.offset("aoe") == -12 * 3600)
        check("UTC+0 is zero", Zone.offset("UTC+0") == 0)
        check("bare UTC is zero", Zone.offset("UTC") == 0)
        check("UTC-8 is west", Zone.offset("UTC-8") == -8 * 3600)
        check("UTC+8 is east", Zone.offset("UTC+8") == 8 * 3600)
        check("half-hour zones survive", Zone.offset("UTC+5:30") == 5 * 3600 + 1800)
        check("an unknown zone is refused rather than guessed",
              Zone.offset("Pacific") == nil && Zone.offset("") == nil,
              "a deadline in the wrong zone is worse than a deadline not shown")

        let aoe = Zone.date("2026-09-25 23:59:59", in: "AoE")
        let utc = Zone.date("2026-09-25 23:59:59", in: "UTC+0")
        check("the same wall clock in AoE is later than in UTC",
              aoe != nil && utc != nil && aoe! > utc!)
        check("and later by exactly twelve hours",
              aoe!.timeIntervalSince(utc!) == 12 * 3600,
              "off by \((aoe!.timeIntervalSince(utc!)) / 3600) hours")

        // --- countdown wording
        let base = Date(timeIntervalSince1970: 1_000_000)
        check("days and hours", Countdown.text(from: base, to: base.addingTimeInterval(90_000)) == "1d 01h")
        check("hours and minutes",
              Countdown.text(from: base, to: base.addingTimeInterval(3600 * 5 + 120)) == "5h 02m")
        check("minutes alone", Countdown.text(from: base, to: base.addingTimeInterval(300)) == "5m")
        check("a passed deadline says so",
              Countdown.text(from: base, to: base.addingTimeInterval(-60)) == "passed")
        check("hours are zero-padded so the column does not jump",
              Countdown.text(from: base, to: base.addingTimeInterval(86_400 + 3600)) == "1d 01h")

        check("two days out is urgent",
              Countdown.urgency(from: base, to: base.addingTimeInterval(86_400)) == .imminent)
        check("five days out is soon",
              Countdown.urgency(from: base, to: base.addingTimeInterval(5 * 86_400)) == .soon)
        check("a month out is just information",
              Countdown.urgency(from: base, to: base.addingTimeInterval(30 * 86_400)) == .distant)

        // --- parsing the feed, against a real sample of the real format
        let sample = """
        - title: ICLR
          description: International Conference on Learning Representations
          sub: AI
          confs:
            - year: 2026
              id: iclr26
              link: https://iclr.cc/Conferences/2026
              timeline:
                - abstract_deadline: '2025-09-19 23:59:59'
                  deadline: '2025-09-24 23:59:59'
              timezone: AoE
              date: April 2026
              place: Rio de Janeiro, Brazil
            - year: 2027
              id: iclr27
              link: https://iclr.cc/Conferences/2027
              timeline:
                - abstract_deadline: '2026-09-18 23:59:59'
                  deadline: '2026-09-25 23:59:59'
              timezone: AoE
              date: April 26-30, 2027
              place: San Francisco, CA, USA
        """
        let parsed = Feed.parse(sample)
        check("both years are read", Set(parsed.map(\.year)) == [2026, 2027],
              "got \(Set(parsed.map(\.year)).sorted())")
        check("both kinds are read for a year",
              parsed.filter { $0.year == 2027 }.map(\.kind).sorted { $0.rawValue < $1.rawValue }
                == [.abstract, .paper])
        check("the conference keeps its name", parsed.allSatisfy { $0.conference == "ICLR" })
        check("the zone is carried through", parsed.allSatisfy { $0.zone == "AoE" })
        check("the place is picked up",
              parsed.first { $0.year == 2027 }?.place == "San Francisco, CA, USA")
        check("the deadline is the AoE instant, not the naive one",
              parsed.first { $0.year == 2027 && $0.kind == .paper }?.at
                == Zone.date("2026-09-25 23:59:59", in: "AoE"))
        check("nonsense parses to nothing rather than to a wrong date",
              Feed.parse("this is not yaml at all").isEmpty)

        // --- which deadline is "next"
        let now = Zone.date("2026-08-08 12:00:00", in: "UTC+0")!
        let iclr = Feed.parse(sample)
        let standings = Schedule.standings(for: ["ICLR", "NeurIPS"], in: iclr, now: now)
        check("a conference with nothing ahead is reported, not dropped",
              standings.contains { standing in
                  if case .unannounced(let name, _) = standing { return name == "NeurIPS" }
                  return false
              },
              "a missing row reads as nothing to do, which is a different claim")
        let upcoming = standings.compactMap { standing -> Deadline? in
            if case .upcoming(let d) = standing { return d }
            return nil
        }
        check("last year's round is not offered as the next one",
              upcoming.allSatisfy { $0.year == 2027 },
              "got years \(Set(upcoming.map(\.year)).sorted())")
        check("both of the next round's deadlines are shown", upcoming.count == 2,
              "the abstract deadline is the one people miss")
        check("soonest first", upcoming.first?.kind == .abstract)
        check("an unannounced conference sorts below real deadlines",
              {
                  if case .upcoming = standings.first { return true }
                  return false
              }())

        // --- the file format
        let listed = Store.parseList("""
            # a comment
            NeurIPS

            ICML
            My Workshop | 2026-11-14 23:59 UTC-8 | abstract
            Bare Date | 2026-12-01 AoE
            broken line |
            """)
        check("plain names are tracked", listed.tracked == ["NeurIPS", "ICML"],
              "got \(listed.tracked)")
        check("comments and blank lines are ignored",
              !listed.tracked.contains { $0.hasPrefix("#") || $0.isEmpty })
        check("a hand-written deadline is parsed",
              listed.manual.first?.conference == "My Workshop")
        check("its kind is honoured", listed.manual.first?.kind == .abstract)
        check("its zone is honoured",
              listed.manual.first?.at == Zone.date("2026-11-14 23:59:00", in: "UTC-8"))
        check("a date with no time means the end of that day",
              listed.manual.first { $0.conference == "Bare Date" }?.at
                == Zone.date("2026-12-01 23:59:59", in: "AoE"))
        check("a malformed line is skipped rather than crashing",
              listed.manual.count == 2, "got \(listed.manual.count)")

        // --- the cache round-trip, which is what makes it right offline
        let sampleDeadlines = Feed.parse(sample)
        let restored = Store.decode(Store.encode(sampleDeadlines))
        check("the cache round-trips every field",
              restored.count == sampleDeadlines.count
                && zip(restored, sampleDeadlines).allSatisfy {
                    $0.conference == $1.conference && $0.year == $1.year
                        && $0.kind == $1.kind && $0.zone == $1.zone
                        && abs($0.at.timeIntervalSince($1.at)) < 1
                },
              "a lossy cache means wrong dates on a train")

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
