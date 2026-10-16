import Foundation
import Tokenizers
import CoreML
import Accelerate
import Darwin
import CryptoKit

struct Golden: Decodable { let text:String; let normalized:String; let input_ids:[Int] }
let root=URL(fileURLWithPath:"/private/tmp/picedit-semantic-gate")
func seconds(_ start: Date) -> Double { Date().timeIntervalSince(start) }
func rss() -> Int64 { var r=rusage(); getrusage(RUSAGE_SELF, &r); return Int64(r.ru_maxrss) }
func write(_ object:Any,_ file:String) throws {
 try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(file))
}
let arguments=Array(CommandLine.arguments.dropFirst())
guard let mode=arguments.first, ["all","cpu"].contains(mode) else { fatalError("mode all/cpu required") }
func option(_ key:String,_ fallback:String)->String { guard let i=arguments.firstIndex(of:key),i+1<arguments.count else{return fallback};return arguments[i+1] }
let lifecycle=option("--lifecycle","tokenizer-first")
precondition(["tokenizer-first","models-first-pool","text-first-per-model-pool"].contains(lifecycle))
let runtime=URL(fileURLWithPath:option("--runtime",root.appendingPathComponent("runtime-fp32-isolated").path))
let outputName=option("--output","native-fp32-isolated-"+lifecycle+"-"+mode+"-results.json")
precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent(outputName).path),"Preserve prior results")
let truthData=try Data(contentsOf:root.appendingPathComponent("ground-truth.json"))
let truthHash=SHA256.hash(data:truthData).map{String(format:"%02x",$0)}.joined()
precondition(truthHash=="c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025")
func residentRSS()->UInt64 {
 var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
 let status=withUnsafeMutablePointer(to:&info){ pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){ task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
 return status==KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
var stages:[[String:Any]]=[]
func stage(_ name:String){stages.append(["stage":name,"peak_rss_bytes":rss(),"resident_rss_bytes":residentRSS()])}
let baselineResident=residentRSS()
let baseline=rss()
stage("baseline-before-model-and-tokenizer")
let config=MLModelConfiguration();config.computeUnits=mode=="cpu" ? .cpuOnly : .all
var loadSeconds=Double(0)
func loadModels() throws -> (MLModel,MLModel) {
 let start=Date()
 if lifecycle=="text-first-per-model-pool" {
  let text=try autoreleasepool {try MLModel(contentsOf:runtime.appendingPathComponent("models/text.mlmodelc"),configuration:config)}
  stage("text-model-loaded-pool-drained")
  let image=try autoreleasepool {try MLModel(contentsOf:runtime.appendingPathComponent("models/image.mlmodelc"),configuration:config)}
  loadSeconds=seconds(start);stage("image-model-loaded-pool-drained")
  return(image,text)
 }
 let image=try MLModel(contentsOf:runtime.appendingPathComponent("models/image.mlmodelc"),configuration:config)
 stage("image-model-loaded")
 let text=try MLModel(contentsOf:runtime.appendingPathComponent("models/text.mlmodelc"),configuration:config)
 loadSeconds=seconds(start);stage("text-model-loaded")
 return(image,text)
}
let earlyModels:(MLModel,MLModel)?=lifecycle != "tokenizer-first" ? try autoreleasepool {try loadModels()} : nil
let tokenizerStart=Date()
let tokenizer = try await AutoTokenizer.from(modelFolder:runtime.appendingPathComponent("tokenizer"))
let tokenizerSeconds=seconds(tokenizerStart)
stage("tokenizer-loaded")
let golden = try JSONDecoder().decode([Golden].self,from:Data(contentsOf:root.appendingPathComponent("token-golden.json")))
func tokenize(_ text:String)->[Int] {
 var tokens=tokenizer.encode(text:text.lowercased(),addSpecialTokens:false)
 tokens=Array(tokens.prefix(63))+[1]
 return tokens+Array(repeating:0,count:64-tokens.count)
}
var failures=0
for (index,g) in golden.enumerated() {
 let normalized=g.text.lowercased()
 let tokens=tokenize(g.text)
 let equal=normalized==g.normalized && tokens==g.input_ids
 if !equal { failures+=1; print("FAIL \(index) expected \(g.input_ids), got \(tokens)") }
}
print("Tokenizer golden failures: \(failures)/\(golden.count)")
if failures>0 { exit(1) }

struct Query:Decodable {let id:String;let language:String;let text:String;let input_ids:[Int]}
struct Reference:Decodable {let rows:[Query]}
struct Asset:Decodable {let id:String}
struct TruthQuery:Decodable {let id:String;let relevant_asset_ids:[String]}
struct Truth:Decodable {let assets:[Asset];let queries:[TruthQuery]}
let rows=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:root.appendingPathComponent("reference-results.json"))).rows
let truth=try JSONDecoder().decode(Truth.self,from:truthData)
let assets=truth.assets
precondition(assets.count==30 && rows.count==50)
for row in rows { if tokenize(row.text) != row.input_ids { fatalError("Query token mismatch \(row.id)/\(row.language)") } }
func floats(_ file:String)throws->[Float] {
 let data=try Data(contentsOf:root.appendingPathComponent(file))
 return data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
}
func normalize(_ v:[Float])->[Float] {
 let sum=v.reduce(Float(0)){$0+$1*$1}.squareRoot()
 precondition(v.count==768 && sum.isFinite && sum>0)
 return v.map{$0/sum}
}
func predict(_ model:MLModel,_ values:[Float],_ shape:[NSNumber],_ name:String)throws->[Float] {
 let input=try MLMultiArray(shape:shape,dataType:.float32)
 for (i,v) in values.enumerated(){input[i]=NSNumber(value:v)}
 let result=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:[name:input]))
 let output=result.featureValue(for:"embedding")!.multiArrayValue!
 return normalize((0..<output.count).map{output[$0].floatValue})
}
func encode(_ model:MLModel,_ text:String)throws->[Float] {
 let ids=tokenize(text)
 let input=try MLMultiArray(shape:[1,64],dataType:.int32)
 for (i,v) in ids.enumerated(){input[i]=NSNumber(value:v)}
 let result=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["input_ids":input]))
 let output=result.featureValue(for:"embedding")!.multiArrayValue!
 return normalize((0..<output.count).map{output[$0].floatValue})
}
func cosine(_ a:[Float],_ b:ArraySlice<Float>)->Float {
 zip(a,b).reduce(Float(0)){$0+$1.0*$1.1}
}
let (image,text)=try earlyModels ?? loadModels()
stage("all-models-and-tokenizer-loaded")
let imageRef=try floats("reference-images.f32"),queryRef=try floats("reference-queries.f32")
var imageVectors:[[Float]]=[],queryVectors:[[Float]]=[]
var imageTimes:[Double]=[],queryTimes:[Double]=[],imageErrors:[Double]=[],queryErrors:[Double]=[]
for (i,a) in assets.enumerated() {
 let input=try floats(a.id+"-input.f32"),start=Date()
 let vector=try predict(image,input,[1,3,256,256],"pixels")
 imageTimes.append(seconds(start));imageVectors.append(vector)
 imageErrors.append(Double(1-cosine(vector,imageRef[(i*768)..<((i+1)*768)])))
}
stage("image-encoding-complete")
for (i,row) in rows.enumerated() {
 let start=Date(),vector=try encode(text,row.text)
 queryTimes.append(seconds(start));queryVectors.append(vector)
 queryErrors.append(Double(1-cosine(vector,queryRef[(i*768)..<((i+1)*768)])))
}
stage("query-encoding-complete")
// 10k normalized synthetic vectors, deterministic independent of fixture labels.
var state:UInt64=0x50494345444954
var index=[Float]();index.reserveCapacity(10000*768)
for _ in 0..<10000 {
 var vector=[Float]();vector.reserveCapacity(768)
 for _ in 0..<768 {state=state &* 6364136223846793005 &+ 1442695040888963407;vector.append(Float(Int32(truncatingIfNeeded:state>>32))/Float(Int32.max))}
 index.append(contentsOf:normalize(vector))
}
stage("10000-vector-index-built")
func search(_ vector:[Float])->[Int] {
 var scores=[Float](repeating:0,count:10000)
 vDSP_mmul(index,1,vector,1,&scores,1,10000,1,768)
 return scores.indices.sorted{scores[$0]==scores[$1] ? $0<$1 : scores[$0]>scores[$1]}.prefix(100).map{$0}
}
var fullTimes:[Double]=[],searchTimes:[Double]=[],cachedTimes:[Double]=[]
for i in 0..<100 {
 let start=Date(),vector=try encode(text,rows[i%rows.count].text)
 let searchStart=Date();let hits=search(vector);precondition(hits.count==100)
 searchTimes.append(seconds(searchStart));fullTimes.append(seconds(start))
 let cachedStart=Date();_ = search(queryVectors[i%rows.count]);cachedTimes.append(seconds(cachedStart))
}
func percentile(_ xs:[Double],_ fraction:Double)->Double {let sorted=xs.sorted();return sorted[max(0,Int(ceil(Double(xs.count)*fraction))-1)]}
stage("warm-query-loop-complete")
let relevant=Dictionary(uniqueKeysWithValues:truth.queries.map{($0.id,Set($0.relevant_asset_ids))})
var retrieval:[[String:Any]]=[],hits=["de":0,"en":0]
for(i,row) in rows.enumerated(){
 let scores=imageVectors.map{vector in zip(vector,queryVectors[i]).reduce(Float(0)){$0+$1.0*$1.1}}
 let order=scores.indices.sorted{scores[$0]==scores[$1] ? assets[$0].id<assets[$1].id : scores[$0]>scores[$1]}
 let hit=relevant[row.id].map{set in order.prefix(5).contains{set.contains(assets[$0].id)}} ?? false
 if hit {hits[row.language,default:0]+=1}
 retrieval.append(["id":row.id,"language":row.language,"hit_top5":hit,"ranking":order.map{["asset":assets[$0].id,"score":scores[$0]] as [String:Any]}])
}
let runtimeFiles=try FileManager.default.subpathsOfDirectory(atPath:runtime.path).compactMap{path -> [String:Any]? in
 let url=runtime.appendingPathComponent(path),values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey])
 guard values.isRegularFile==true else {return nil}
 precondition(values.isSymbolicLink != true)
 return["path":path,"bytes":values.fileSize ?? 0]
}.sorted{($0["path"] as! String)<($1["path"] as! String)}
let runtimeBytes=runtimeFiles.reduce(0){$0+($1["bytes"] as! Int)}
let parity=(imageErrors+queryErrors).allSatisfy{$0<=0.001}
let quality=hits.values.allSatisfy{$0>=16} && abs(hits["de"]!-hits["en"]!)<=2
let extraRSS=rss()-baseline
let gates:[String:Bool]=["parity":parity,"exact_token_ids":failures==0,"quality":quality,"runtime_files":runtimeBytes<=1_073_741_824,"extra_peak_rss":extraRSS<=1_610_612_736,"warm_full_query_p95":percentile(fullTimes,0.95)<=0.5]
let output:[String:Any]=["lifecycle":lifecycle,"ground_truth_sha256":truthHash,"cache_state":"fresh process and empty app model/query caches; OS/CoreML cache already used, no purge; not first installation", "baseline_resident_rss_bytes":baselineResident,"stages":stages,"gates":gates,"all_gates_passed":gates.values.allSatisfy{$0},"runtime_files":runtimeFiles,"runtime_files_bytes":runtimeBytes,"retrieval":retrieval,"quality_top5_hits_each_of20":hits,"index_vectors":10000,"index_dimension":768,"image_index_total_seconds":imageTimes.reduce(0,+),"image_index_images_per_second":30/imageTimes.reduce(0,+),"image_index_warm_images_per_second":29/imageTimes.dropFirst().reduce(0,+),"warm_full_query_seconds":fullTimes,"search_seconds":searchTimes,"cached_query_seconds":cachedTimes,"cached_query_p50_seconds":percentile(cachedTimes,0.5),"mode":mode,"baseline_peak_rss_bytes":baseline,"peak_rss_bytes":rss(),"extra_peak_rss_bytes":rss()-baseline,"tokenizer_load_seconds":tokenizerSeconds,"model_load_seconds":loadSeconds,"image_seconds":imageTimes,"query_encoding_seconds":queryTimes,"image_cosine_distance":imageErrors,"query_cosine_distance":queryErrors,"warm_full_query_p50_seconds":percentile(fullTimes,0.5),"warm_full_query_p95_seconds":percentile(fullTimes,0.95),"search_p50_seconds":percentile(searchTimes,0.5),"search_p95_seconds":percentile(searchTimes,0.95),"cached_query_p95_seconds":percentile(cachedTimes,0.95),"vectors":queryVectors,"image_vectors":imageVectors]
try write(output,outputName)
print(output.filter{!["vectors","image_vectors","image_seconds","query_encoding_seconds","image_cosine_distance","query_cosine_distance","retrieval","runtime_files","warm_full_query_seconds","search_seconds","cached_query_seconds"].contains($0.key)})
fflush(stdout)
exit(gates.values.allSatisfy{$0} ? 0 : 2)
