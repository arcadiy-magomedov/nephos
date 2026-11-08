#!/usr/bin/env python3
"""Generate the dependency-free iOS project using stable IDs. Run from any directory."""

import hashlib
import pathlib
import plistlib

ROOT = pathlib.Path(__file__).resolve().parent
PROJECT = ROOT / "Nephos.xcodeproj"


def oid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def generate():
    sources = sorted((ROOT / "Nephos").rglob("*.swift"))
    objects = []

    def add(name, body):
        objects.append(f"\t\t{oid(name)} = {{ {body} }};")

    for source in sources:
        path = source.relative_to(ROOT).as_posix()
        add(
            path,
            f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;",
        )
        add("build:" + path, f"isa = PBXBuildFile; fileRef = {oid(path)};")
    add(
        "product",
        "isa = PBXFileReference; explicitFileType = wrapper.application; path = Nephos.app; sourceTree = BUILT_PRODUCTS_DIR;",
    )
    add("products", f'isa = PBXGroup; children = ({oid("product")},); name = Products; sourceTree = "<group>";')
    children = ",".join(oid(s.relative_to(ROOT).as_posix()) for s in sources)
    add("main", f'isa = PBXGroup; children = ({children},{oid("products")},); sourceTree = "<group>";')
    builds = ",".join(oid("build:" + s.relative_to(ROOT).as_posix()) for s in sources)
    add(
        "sources",
        f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({builds},); runOnlyForDeploymentPostprocessing = 0;",
    )
    add(
        "frameworks",
        "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
    )
    add(
        "resources",
        "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
    )
    for config in ("Debug", "Release"):
        project_settings = {
            "SDKROOT": "iphoneos",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "SWIFT_VERSION": "5.0",
            "CLANG_ENABLE_MODULES": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if config == "Debug" else "",
        }
        target_settings = {
            "PRODUCT_NAME": "Nephos",
            "PRODUCT_BUNDLE_IDENTIFIER": "app.nephos.ios",
            "MARKETING_VERSION": "0.1.0",
            "CURRENT_PROJECT_VERSION": "1",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": f"Nephos/Info-{config}.plist",
            "CODE_SIGN_STYLE": "Automatic",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        }
        for name, settings in (("project", project_settings), ("target", target_settings)):
            body = " ".join(f"{key} = {quote(value)};" for key, value in settings.items())
            add(f"{name}:{config}", f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};")
    for name in ("project", "target"):
        add(
            name + ":configs",
            f"isa = XCConfigurationList; buildConfigurations = ({oid(name + ':Debug')},{oid(name + ':Release')},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
        )
    add(
        "target",
        f'isa = PBXNativeTarget; buildConfigurationList = {oid("target:configs")}; buildPhases = ({oid("sources")},{oid("frameworks")},{oid("resources")},); buildRules = (); dependencies = (); name = Nephos; productName = Nephos; productReference = {oid("product")}; productType = "com.apple.product-type.application";',
    )
    add(
        "project",
        f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }}; buildConfigurationList = {oid("project:configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {oid("main")}; productRefGroup = {oid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({oid("target")},);',
    )
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(
        "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
        + "\n".join(objects)
        + f"\n\t}};\n\trootObject = {oid('project')};\n}}\n"
    )
    scheme = PROJECT / "xcshareddata/xcschemes/Nephos.xcscheme"
    scheme.parent.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid("target")}" BuildableName="Nephos.app" BlueprintName="Nephos" ReferencedContainer="container:Nephos.xcodeproj"/>'
    scheme.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
  <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries>
 </BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""")
    base = {
        "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Nephos",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True,
        "NSCameraUsageDescription": "Scan your administrator's single-use Nephos sign-in QR code.",
        "NSLocalNetworkUsageDescription": "Connect to the Nephos server in your administrator's QR code.",
        "UILaunchScreen": {},
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
    }
    for config in ("Debug", "Release"):
        info = dict(base)
        with (ROOT / f"Nephos/Info-{config}.plist").open("wb") as file:
            plistlib.dump(info, file, sort_keys=True)


if __name__ == "__main__":
    generate()
