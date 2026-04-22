import Foundation

// Called from the ObjC +load hook in WildEdgeAutoLoader.m — runs before main().
@_cdecl("wildedge_auto_init")
internal func wildedgeAutoInit() {
    WildEdge.autoInit()
}
