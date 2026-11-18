import Foundation

/// DVS Intelligence 1.0. No invented BPM, acoustic similarity or copyrighted Spotify model:
/// - Last.fm listening co-occurrence when a FREE user API key is configured
/// - public catalog's related tracks as lower-confidence candidates
/// - strong checks for exact recording metadata, repeat suppression, user feedback
/// - local, deterministic ordering (no network needed in Smart Shuffle)
struct RecommendationEngine {
    private let catalog = CatalogService()
    private let lastFM = LastFMService()

    private let genres: [String: [String]] = [
        "trap": ["trap", "drill", "rap", "hiphop", "hip hop", "migos", "future", "21 savage", "shiva", "sfera", "capo plaza", "metro boomin", "travis scott", "offset", "quavo", "lil baby", "gunna", "young thug"],
        "indie": ["indie", "alternative", "lofi", "bedroom", "bresh", "psicologi", "olly", "calcutta"],
        "pop": ["pop", "mainstream", "dua lipa", "taylor swift", "ariana grande"],
        "rock": ["rock", "punk", "metal", "grunge", "guitar", "nirvana"],
        "electronic": ["techno", "house", "edm", "electronic", "dance", "fred again"],
        "rnb": ["r&b", "rnb", "soul", "frank ocean", "the weeknd", "sza", "brent faiyaz"],
        "latin": ["reggaeton", "latin", "bachata", "salsa", "bad bunny", "urbano", "rauw alejandro"]
    ]

    struct Candidate {
        let track: MusicTrack
        let relevance: Double // higher means a better verified match to the source song
    }

    /// Exposed for repeatable, network-free tests.
    func rank(_ candidates: [Candidate], near anchor: MusicTrack, excluding excluded: Set<String>,
              favorites: [MusicTrack], history: [String: ListeningRecord], exploration: Double,
              blockedCanonical: Set<String> = []) -> [MusicTrack] {
        let reference = MusicMetadata.identity(for: anchor)
        let referenceGenres = genreSet(anchor)
        let excludedCanonical = Set(history.values.filter { $0.skips >= 3 && $0.skips > $0.plays }
            .map { MusicMetadata.canonicalKey($0.track) })
        let favoriteKeys = Set(favorites.map { MusicMetadata.canonicalKey($0) })
        var candidateScores: [String: (MusicTrack, Double)] = [:]
        let novelty = min(1, max(0, exploration))
        let anchorArtist = MusicMetadata.normalized(reference.artist)
        let excludeKeys = Set(candidates.filter { excluded.contains($0.track.id) }.map { MusicMetadata.canonicalKey($0.track) })
        for item in candidates {
            let candidate = item.track
            guard candidate.id != anchor.id, !excluded.contains(candidate.id),
                  MusicMetadata.isMusic(candidate) else { continue }
            let key = MusicMetadata.canonicalKey(candidate)
            guard key != MusicMetadata.canonicalKey(anchor), !excludeKeys.contains(key),
                  !excludedCanonical.contains(key), !blockedCanonical.contains(key) else { continue }
            let candidateInfo = MusicMetadata.identity(for: candidate)
            let candidateArtist = MusicMetadata.normalized(candidateInfo.artist)
            var score = item.relevance
            let commonGenres = referenceGenres.intersection(genreSet(candidate)).count
            score += Double(commonGenres) * 12
            // Reduce monotony: user wants songs similar in style, not only the same artist.
            if !anchorArtist.isEmpty && candidateArtist == anchorArtist { score -= 16 }
            else { score += 4 }
            if candidate.duration >= 120 && candidate.duration <= 420 { score += 4 }
            if favoriteKeys.contains(key) { score += 12 * (1 - novelty) }
            if history[candidate.id] == nil { score += 12 * novelty }
            if let record = history[candidate.id] {
                score += min(12, Double(record.plays) * 2.5) * (1 - novelty / 2)
                score -= Double(record.skips) * 24
                if Date().timeIntervalSince(record.lastPlayed) < 12 * 3600 { score -= 28 }
            }
            // Prefer original recordings over upload duplicates, but do not fake audio features.
            let title = MusicMetadata.normalized(candidate.title)
            score += min(15, Double(OfficialCatalog.sourceConfidence(candidate)) * 0.15)
            if title.contains("live") || title.contains("remix") || title.contains("sped") { score -= 30 }
            if let previous = candidateScores[key] {
                let earlierSource = OfficialCatalog.sourceConfidence(previous.0)
                let newSource = OfficialCatalog.sourceConfidence(candidate)
                // Source preference is STRONG only when comparing two uploads
                // of the *same* recording, not unrelated recommended songs.
                if newSource > earlierSource && score >= previous.1 - 65 {
                    // Prefer the official-source hint.
                } else if score <= previous.1 || (newSource < earlierSource && score < previous.1 + 65) {
                    continue
                }
            }
            candidateScores[key] = (candidate, score)
        }
        return candidateScores.values.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.id < b.0.id
        }.prefix(32).map { $0.0 }
    }

    func recommendations(near track: MusicTrack, excluding excluded: Set<String>,
                         favorites: [MusicTrack] = [], history: [String: ListeningRecord] = [:],
                         apiKey: String = "", exploration: Double = 0.35,
                         blockedCanonical: Set<String> = []) async -> [MusicTrack] {
        // Run both providers concurrently. Playback never awaits this method; the radio loads ahead.
        async let relatedTask = catalog.suggested(near: track)
        async let similarTask = lastFM.similar(to: track, apiKey: apiKey)
        let similars = await similarTask
        var candidates: [Candidate] = []

        // Metadata match is strict: artist+song, not "first result for the query".
        if !similars.isEmpty {
            await withTaskGroup(of: Candidate?.self) { group in
                for suggestion in similars.prefix(10) {
                    group.addTask {
                        guard let results = try? await catalog.search("\(suggestion.artist) \(suggestion.title)") else { return nil }
                        let scored = results.compactMap { result -> (MusicTrack, Double)? in
                            guard MusicMetadata.isMusic(result) else { return nil }
                            let info = MusicMetadata.identity(for: result)
                            let titleMatch = MusicMetadata.titleMatch(suggestion.title, candidate: info.title)
                            let artistMatch = MusicMetadata.artistMatch(suggestion.artist, candidate: result)
                            guard titleMatch >= 0.72, artistMatch else { return nil }
                            var quality = titleMatch * 32
                            quality += min(22, Double(OfficialCatalog.sourceConfidence(result)) * 0.22)
                            return (result, quality)
                        }.max { $0.1 < $1.1 }
                        return scored.map { Candidate(track: $0.0, relevance: 65 + suggestion.match * 100 + $0.1) }
                    }
                }
                for await found in group { if let found { candidates.append(found) } }
            }
        }
        let related = await relatedTask
        for (i, result) in related.enumerated() where MusicMetadata.isMusic(result) {
            // Recommended videos are less trustworthy than a verified Last.fm song match.
            candidates.append(Candidate(track: result, relevance: max(6, 39 - Double(i) * 1.2)))
        }
        // Related-video feeds frequently contain user reuploads. Resolve just a
        // few of the top picks toward a Topic/VEVO version in the *radio task*,
        // leaving existing AVQueuePlayer items completely untouched.
        // If there is no matching distributor upload, keep the original result.
        await withTaskGroup(of: Candidate?.self) { group in
            for (index, suggestion) in related.prefix(5).enumerated() {
                guard MusicMetadata.isMusic(suggestion),
                      OfficialCatalog.sourceConfidence(suggestion) < 80 else { continue }
                let source = MusicMetadata.identity(for: suggestion)
                group.addTask {
                    let search = source.artist + " " + source.title
                    guard let found = try? await catalog.search(search),
                          let replacement = found.first(where: {
                              MusicMetadata.canonicalKey($0) == MusicMetadata.canonicalKey(suggestion) &&
                              OfficialCatalog.sourceConfidence($0) >= 65
                          }) else { return nil }
                    return Candidate(track: replacement, relevance: max(6, 39 - Double(index) * 1.2))
                }
            }
            for await enhanced in group { if let enhanced { candidates.append(enhanced) } }
        }
        // Fallback search only if external sources yielded too few playable candidates.
        if candidates.count < 7 {
            let info = MusicMetadata.identity(for: track)
            if let local = try? await catalog.search("\(info.artist) similar music official audio") {
                candidates.append(contentsOf: local.prefix(18).map { Candidate(track: $0, relevance: 9) })
            }
        }
        return rank(candidates, near: track, excluding: excluded,
                    favorites: favorites, history: history, exploration: exploration,
                    blockedCanonical: blockedCanonical)
    }

    func smartOrder(_ tracks: [MusicTrack], following anchor: MusicTrack?,
                    favorites: [MusicTrack], history: [String: ListeningRecord], exploration: Double = 0.35,
                    blockedCanonical: Set<String> = []) -> [MusicTrack] {
        let favoriteKeys = Set(favorites.map { MusicMetadata.canonicalKey($0) })
        var preferred: [String: MusicTrack] = [:]
        for track in tracks where MusicMetadata.isMusic(track) {
            let key = MusicMetadata.canonicalKey(track)
            guard !blockedCanonical.contains(key) else { continue }
            if let prior = preferred[key], OfficialCatalog.sourceConfidence(prior) >= OfficialCatalog.sourceConfidence(track) {
                continue
            }
            preferred[key] = track
        }
        var remaining = Array(preferred.values)
        var result: [MusicTrack] = []
        var previous = anchor
        let novelty = min(1, max(0, exploration))
        while !remaining.isEmpty {
            let referenceGenres = previous.map(genreSet) ?? []
            let previousArtist = previous.map { MusicMetadata.normalized(MusicMetadata.identity(for: $0).artist) } ?? ""
            let best = remaining.indices.max { left, right in
                func score(_ track: MusicTrack) -> Double {
                    let artist = MusicMetadata.normalized(MusicMetadata.identity(for: track).artist)
                    var value = Double(genreSet(track).intersection(referenceGenres).count) * 18
                    if !previousArtist.isEmpty && artist == previousArtist { value -= 35 }
                    if favoriteKeys.contains(MusicMetadata.canonicalKey(track)) { value += 9 * (1 - novelty) }
                    if history[track.id] == nil { value += 10 * novelty }
                    if let rec = history[track.id] { value += min(10, Double(rec.plays) * 2) - Double(rec.skips) * 18 }
                    return value
                }
                let lhs = score(remaining[left]), rhs = score(remaining[right])
                return lhs == rhs ? remaining[left].id > remaining[right].id : lhs < rhs
            }!
            let next = remaining.remove(at: best)
            result.append(next)
            previous = next
        }
        return result
    }

    private func genreSet(_ track: MusicTrack) -> Set<String> {
        let info = MusicMetadata.identity(for: track)
        let text = MusicMetadata.normalized(info.artist + " " + info.title)
        return Set(genres.compactMap { genre, terms in
            terms.contains(where: { text.contains($0) }) ? genre : nil
        })
    }
}
