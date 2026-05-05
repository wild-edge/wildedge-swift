import Foundation

// Called from the ObjC +load hook in WildEdgeAutoLoader.m — runs before main().
@_cdecl("wildedge_auto_init")
public func wildedgeAutoInit() {
    WildEdge.autoInit()
}
