//
//  RemoteScene3D.swift
//  HyperVibe (settings UI — Layout tab)
//
//  A gorgeous physically-based aluminum 3rd-gen Siri Remote, rendered from the real STL mesh
//  (ModelIO imports STL → SceneKit; SceneKit can't read STL natively). A procedural studio
//  gradient serves as the image-based light so the metal has something bright to reflect.
//  Slowly rotates about its long axis; drag to orbit. A showpiece companion to the interactive
//  2D illustration used for editing.
//

import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO
import AppKit

struct RemoteScene3D: View {
    /// Cached once — building the scene parses the mesh + generates the environment image.
    @State private var scene: SCNScene? = RemoteScene3D.makeScene()

    var body: some View {
        Group {
            if let scene = scene {
                SceneView(scene: scene,
                          options: [.allowsCameraControl, .rendersContinuously],
                          antialiasingMode: .multisampling4X)
                    .background(Color.clear)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("3D model unavailable")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Scene construction

    /// Locate the bundled STL — from the .app bundle once packaged, else next to the dev binary,
    /// else the source tree (so it works before packaging too).
    static func stlURL() -> URL? {
        if let u = Bundle.main.url(forResource: "SiriRemote", withExtension: "stl") { return u }
        let fm = FileManager.default
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let u = exeDir.appendingPathComponent("Resources/SiriRemote.stl")
            if fm.fileExists(atPath: u.path) { return u }
        }
        let dev = URL(fileURLWithPath:
            "/Users/zhangwenqian/siriRemote/hypervibe/Resources/SiriRemote.stl")
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }

    static func makeScene() -> SCNScene? {
        guard let url = stlURL(), MDLAsset.canImportFileExtension("stl") else { return nil }
        let asset = MDLAsset(url: url)
        // STL stores only per-face normals → flat, faceted shading. Recompute smooth vertex
        // normals so the low-poly shell reads as polished aluminum, not a cut gem.
        if let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.98)
        }
        let scene = SCNScene(mdlAsset: asset)
        guard let geom = firstGeometryNode(scene.rootNode) else { return nil }

        // Center the mesh on the origin so it rotates about its middle.
        let (minB, maxB) = geom.boundingBox
        let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        geom.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        geom.position = SCNVector3Zero

        // Aluminum: physically-based metal with a soft reflection.
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(calibratedWhite: 0.82, alpha: 1)
        mat.metalness.contents = 0.95
        mat.roughness.contents = 0.28
        mat.isDoubleSided = true
        geom.geometry?.materials = [mat]

        // Image-based light — a studio gradient gives the metal a bright-to-dark sheen.
        let env = studioEnvironment()
        scene.lightingEnvironment.contents = env
        scene.lightingEnvironment.intensity = 1.6
        scene.background.contents = NSColor.clear

        // Key + rim directional lights for a crisp highlight streak.
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional
        key.light!.intensity = 620
        key.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode(); rim.light = SCNLight(); rim.light!.type = .directional
        rim.light!.intensity = 360
        rim.eulerAngles = SCNVector3(Float.pi / 5, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(rim)

        // Camera framing — the remote is ~136mm on Y (its long axis).
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera!.fieldOfView = 20
        cam.camera!.zNear = 1
        cam.camera!.zFar = 4000          // mesh sits ~470 units out; default far-plane (100) would clip it
        cam.camera!.wantsHDR = true
        cam.camera!.bloomIntensity = 0.18
        cam.camera!.bloomThreshold = 0.75
        cam.position = SCNVector3(0, 0, 470)
        scene.rootNode.addChildNode(cam)

        // A gentle 3/4 resting tilt, then a slow spin about the long axis.
        geom.eulerAngles = SCNVector3(-0.12, 0.55, 0)
        geom.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 24)))

        return scene
    }

    static func firstGeometryNode(_ n: SCNNode) -> SCNNode? {
        if n.geometry != nil { return n }
        for c in n.childNodes { if let g = firstGeometryNode(c) { return g } }
        return nil
    }

    /// A soft vertical studio gradient (bright top → dark floor) rendered once into an image,
    /// used as the scene's image-based light so the aluminum reflects a believable environment.
    static func studioEnvironment() -> NSImage {
        let size = NSSize(width: 8, height: 256)
        let img = NSImage(size: size)
        img.lockFocus()
        let grad = NSGradient(colors: [
            NSColor(calibratedWhite: 1.00, alpha: 1),
            NSColor(calibratedWhite: 0.66, alpha: 1),
            NSColor(calibratedWhite: 0.32, alpha: 1),
            NSColor(calibratedWhite: 0.07, alpha: 1),
        ])!
        grad.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        img.unlockFocus()
        return img
    }
}
