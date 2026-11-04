#!/usr/bin/env python3
"""Export existing MIT-licensed BotArtwork CoreGraphics paths; requires macOS Swift.
No image generation, network, app launch or third-party packages. The original stays unchanged.
"""
from pathlib import Path
import hashlib, json, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'CoincideRemoteKit/Sources/CoincideRemoteKit/BotArtwork.swift'
OUTPUT = ROOT / 'windows/Runtime/BotArtworkData.h'
recorder = r'''
import CoreGraphics
import Foundation
public typealias CGContext = RecordingContext
public final class RecordingContext {
    static var detailSide: CGFloat = 100
    struct Op: Codable { var path: String; var clip: [String]; var fill: Bool; var color: [Double]; var width: Double; var minimum: Double }
    var ops: [Op] = [], clips: [String] = [], stack: [[String]] = [], pending: CGPath? = nil
    var color: [Double] = [0,0,0,1], width = 0.0, minimum = 0.0
    func n(_ value: CGFloat) -> String { precondition(value.isFinite); return String(format:"%.5f", Double(value)).replacingOccurrences(of:#"\.?0+$"#,with:"",options:.regularExpression) }
    func path(_ value: CGPath) -> String {
        var parts: [String] = []
        value.applyWithBlock { ptr in
            let e = ptr.pointee
            func p(_ index: Int) -> String { self.n(e.points[index].x)+" "+self.n(e.points[index].y) }
            switch e.type { case .moveToPoint: parts.append("M"+p(0)); case .addLineToPoint: parts.append("L"+p(0)); case .addQuadCurveToPoint: parts.append("Q"+p(0)+" "+p(1)); case .addCurveToPoint: parts.append("C"+p(0)+" "+p(1)+" "+p(2)); case .closeSubpath: parts.append("Z"); @unknown default: fatalError("Unknown path element") }
        }
        return parts.joined(separator:" ")
    }
    public func saveGState() { stack.append(clips) }
    public func restoreGState() { precondition(!stack.isEmpty); clips = stack.removeLast() }
    public func translateBy(x: CGFloat,y: CGFloat) { precondition(x == 0 && y == 0) }
    public func scaleBy(x: CGFloat,y: CGFloat) { precondition(x == 1 && y == 1) }
    public func setLineCap(_ value: CGLineCap) { precondition(value == .round) }
    public func setLineJoin(_ value: CGLineJoin) { precondition(value == .round) }
    public func addPath(_ value: CGPath) { precondition(pending == nil); pending = value }
    public func clip() { clips.append(path(pending!)); pending = nil }
    func setColor(_ value: CGColor) { let c = value.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,intent:.defaultIntent,options:nil)!.components!; precondition(c.count == 4 && c.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }); color = c.map(Double.init) }
    public func setFillColor(_ value: CGColor) { setColor(value) }
    public func setStrokeColor(_ value: CGColor) { setColor(value) }
    public func setLineWidth(_ value: CGFloat, minimum: CGFloat) { self.width = Double(value); self.minimum = Double(minimum) }
    func emit(_ fill: Bool) { ops.append(Op(path:path(pending!),clip:clips,fill:fill,color:color,width:fill ? 0:width,minimum:fill ? 0:minimum)); pending = nil }
    public func fillPath() { emit(true) }
    public func strokePath() { emit(false) }
}
'''
runner = r'''
struct Variant: Codable { var character: String; var tint: String; var detail: Int; var ops: [RecordingContext.Op] }
var variants: [Variant] = []
for character in BotArtwork.Character.allCases { for detail in [16,28,100] { for tint in BotArtwork.Tint.allCases {
    RecordingContext.detailSide = CGFloat(detail)
    let ctx = RecordingContext()
    BotArtwork.draw(character,tint:tint,in:ctx,rect:CGRect(x:0,y:0,width:100,height:100))
    precondition(ctx.stack.isEmpty && ctx.pending == nil)
    variants.append(Variant(character:character.rawValue,tint:tint.rawValue,detail:detail,ops:ctx.ops))
} } }
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(variants))
'''
def export():
    source = SOURCE.read_text()
    substitutions = [('detail: Detail(side: side)', 'detail: Detail(side: RecordingContext.detailSide)'), ('context.setLineWidth(max(units, minimum / scale))', 'context.setLineWidth(units, minimum: minimum)')]
    for before, after in substitutions:
        if source.count(before) != 1: raise RuntimeError('Artwork changed: review recorder substitutions')
        source = source.replace(before,after)
    with tempfile.TemporaryDirectory(prefix='coincide-bot-art-') as temp:
        swift = Path(temp)/'main.swift'; swift.write_text(recorder+'\n'+source+'\n'+runner)
        subprocess.run(['swiftc',str(swift),'-o',str(Path(temp)/'export')],check=True)
        variants = json.loads(subprocess.check_output([str(Path(temp)/'export')]))
    tints = ['sunflower','tangerine','coral','cherry','rose','lilac','sky','mint','leaf','sage','caramel']
    groups = {}
    for variant in variants: groups.setdefault((variant['character'],variant['detail']),[]).append(variant)
    paths = []; path_ids = {}
    def path_id(value):
        if value not in path_ids: path_ids[value]=len(paths); paths.append(value)
        return path_ids[value]
    arrays=[]; sets=[]
    for (character,detail), values in groups.items():
        assert [v['tint'] for v in values] == tints
        reference=values[0]['ops']; ops=[]
        for index,op in enumerate(reference):
            assert len(op['clip'])<=1
            colors=[]
            for value in values:
                candidate=value['ops'][index]
                assert {k:v for k,v in candidate.items() if k!='color'} == {k:v for k,v in op.items() if k!='color'}
                rgba=[max(0,min(255,round(c*255))) for c in candidate['color']]
                colors.append((rgba[0]<<24)|(rgba[1]<<16)|(rgba[2]<<8)|rgba[3])
            ops.append('{'+','.join([str(path_id(op['path'])),str(path_id(op['clip'][0])) if op['clip'] else '-1','true' if op['fill'] else 'false',str(op['width']),str(op['minimum']),'{'+','.join(f'0x{c:08x}u' for c in colors)+'}'])+'}')
        name=f'{character}_{detail}'
        arrays.append('inline constexpr Draw '+name+'[]={\n'+',\n'.join(ops)+'\n};')
        sets.append('{"'+character+'",'+str(detail)+','+name+',std::size('+name+')}')
    header='''#pragma once
// Faithful vector-data port of CoincideRemoteKit/BotArtwork.swift (MIT).
// Copyright (c) 2026 Apoorv Darshan. Generated by windows/scripts/export_bot_artwork.py.
// Source SHA256: '''+hashlib.sha256(SOURCE.read_bytes()).hexdigest()+'''
// Only normalized finite paths, fixed sRGB colors, internal clips and line dimensions.
#include <cstdint>
#include <iterator>
#include <string_view>
namespace coincide::bot_art_data {
struct Draw { unsigned path; int clip; bool fill; double width,minimum; std::uint32_t colors[11]; };
struct Set { std::string_view character; unsigned detail; const Draw* draws; std::size_t count; };
inline constexpr std::string_view paths[]={
'''+',\n'.join(json.dumps(p) for p in paths)+'\n};\n'+'\n'.join(arrays)+'\ninline constexpr Set sets[]={\n'+',\n'.join(sets)+'\n};\n} // namespace coincide::bot_art_data\n'
    OUTPUT.write_text(header)
    print(f'Exported {len(groups)} character/detail sets, {len(paths)} paths, {len(variants)} variants; {len(header)} bytes')
if __name__=='__main__': export()
