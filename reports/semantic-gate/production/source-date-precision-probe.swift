import Foundation
struct Row: Decodable {let id:String;let path:String;let time:Double}
for row in try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath:"/private/tmp/picedit-semantic-date-probe.json"))) {
 let actual = try FileManager.default.attributesOfItem(atPath:row.path)[.modificationDate] as! Date
 let decoded = Date(timeIntervalSince1970:row.time)
 print(row.id,"Date equal",actual==decoded,"epoch equal",actual.timeIntervalSince1970==row.time,"deltaRefNs",(actual.timeIntervalSinceReferenceDate-decoded.timeIntervalSinceReferenceDate)*1e9)
}
