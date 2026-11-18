import Foundation

struct MusicTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let duration: Int

    var artworkURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    static func == (lhs: MusicTrack, rhs: MusicTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct InvidiousVideo: Decodable {
    let type: String?
    let videoId: String?
    let title: String?
    let author: String?
    let lengthSeconds: Int?

    func asTrack() -> MusicTrack? {
        guard let videoId, videoId.count == 11, let title else { return nil }
        if let type, type != "video" { return nil }
        return MusicTrack(id: videoId, title: title, artist: author ?? "YouTube", duration: lengthSeconds ?? 0)
    }
}

struct InvidiousVideoDetail: Decodable {
    let recommendedVideos: [InvidiousVideo]?
}

enum RepeatSetting: String, CaseIterable {
    case off = "Nessuna"
    case all = "Tutte"
}
