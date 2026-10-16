import Foundation
import CoreML
import CryptoKit
import Darwin
let root=URL(fileURLWithPath:"/private/tmp/picedit-semantic-gate")
let arguments=Array(CommandLine.arguments.dropFirst())
precondition(arguments.count>=2)
let variant=arguments[0], mode=arguments[1], suffix=arguments.count>2 ? "-"+arguments[2] : ""
precondition(["cpu","all"].contains(mode))
let target=root.appendingPathComponent("image-"+variant+".mlmodelc")
let destination=root.appendingPathComponent("native-"+variant+"-"+mode+"-image-parity"+suffix+".json")
precondition(!FileManager.default.fileExists(atPath:destination.path),"Preserve previous probe output")
let truthData=try Data(contentsOf:root.appendingPathComponent("ground-truth.json"))
let truthHash=SHA256.hash(data:truthData).map{String(format:"%02x",$0)}.joined()
precondition(truthHash=="c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025")
if !FileManager.default.fileExists(atPath:target.path) {
 let temporary=try MLModel.compileModel(at:root.appendingPathComponent("image-"+variant+".mlpackage"))
 try FileManager.default.copyItem(at:temporary,to:target)
}
struct Asset:Decodable{let id:String}
struct Query:Decodable{let id:String;let language:String;let text:String}
struct TruthQuery:Decodable{let id:String;let relevant_asset_ids:[String]}
struct Truth:Decodable{let assets:[Asset];let queries:[TruthQuery]}
struct Ref:Decodable{let rows:[Query]}
struct Native:Decodable{let vectors:[[Float]]}
let truth=try JSONDecoder().decode(Truth.self,from:truthData)
let rows=try JSONDecoder().decode(Ref.self,from:Data(contentsOf:root.appendingPathComponent("reference-results.json"))).rows
let text=try JSONDecoder().decode(Native.self,from:Data(contentsOf:root.appendingPathComponent(mode=="cpu" ? "native-cpu-results.json" : "native-all-results.json"))).vectors
let relevant=Dictionary(uniqueKeysWithValues:truth.queries.map{($0.id,Set($0.relevant_asset_ids))})
func floats(_ name:String)throws->[Float]{let data=try Data(contentsOf:root.appendingPathComponent(name));return data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}}
func normalize(_ v:[Float])->[Float]{let norm=v.reduce(Float(0)){$0+$1*$1}.squareRoot();precondition(v.count==768 && v.allSatisfy{$0.isFinite} && norm.isFinite && norm>0);return v.map{$0/norm}}
func dot(_ a:[Float],_ b:[Float])->Double{zip(a,b).reduce(0.0){$0+Double($1.0)*Double($1.1)}}
let config=MLModelConfiguration();config.computeUnits=mode=="cpu" ? .cpuOnly : .all
let image=try MLModel(contentsOf:target,configuration:config)
let reference=try floats("reference-images.f32")
var vectors:[[Float]]=[],errors:[Double]=[]
for (index,asset) in truth.assets.enumerated(){
 let values=try floats(asset.id+"-input.f32")
 let input=try MLMultiArray(shape:[1,3,256,256],dataType:.float32)
 for(i,v) in values.enumerated(){input[i]=NSNumber(value:v)}
 let result=try image.prediction(from:MLDictionaryFeatureProvider(dictionary:["pixels":input]))
 let output=result.featureValue(for:"embedding")!.multiArrayValue!
 let vector=normalize((0..<output.count).map{output[$0].floatValue})
 vectors.append(vector);errors.append(1-dot(vector,Array(reference[(index*768)..<((index+1)*768)])))
}
var ranking:[[String:Any]]=[]
var quality=["de":0,"en":0]
for(index,row)in rows.enumerated(){
 let order=vectors.indices.sorted{a,b in let x=dot(vectors[a],text[index]),y=dot(vectors[b],text[index]);return x==y ? truth.assets[a].id<truth.assets[b].id : x>y}
 let hit=relevant[row.id].map{set in order.prefix(5).contains{set.contains(truth.assets[$0].id)}} ?? false
 if hit {quality[row.language,default:0]+=1}
 ranking.append(["id":row.id,"language":row.language,"hit_top5":hit,"ranking":order.map{["asset":truth.assets[$0].id,"score":dot(vectors[$0],text[index])] as [String:Any]}])
}
let output:[String:Any]=["variant":variant,"mode":mode,"purpose":"functional parity only; concurrent root build; no performance claim","ground_truth_sha256":truthHash,"image_cosine_distance":errors,"maximum_image_cosine_distance":errors.max()!,"parity_tolerance":0.001,"parity_passed":errors.allSatisfy{$0<=0.001},"quality_top5_hits_each_of20":quality,"image_vectors":vectors,"rows":ranking,"text_vectors_source":mode=="cpu" ? "native-cpu-results.json" : "native-all-results.json"]
try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.withoutOverwriting)
print("variant=\(variant) mode=\(mode) maxDistance=\(errors.max()!) parity=\(errors.allSatisfy{$0<=0.001}) quality=\(quality)")
exit(errors.allSatisfy{$0<=0.001} ? 0 : 2)
