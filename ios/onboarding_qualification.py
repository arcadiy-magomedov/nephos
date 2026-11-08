#!/usr/bin/env python3
"""Generate the isolated native sign-in XCTest project used by qr_qualification.py."""

from pathlib import Path
import plistlib

from generate_project import oid

IOS = Path(__file__).resolve().parent
BUNDLE = "app.nephos.ui-qualification"


def project(workspace, test_sources=None, app_sources=None):
    objects = {}

    def add(identifier, isa, **values):
        key = oid(identifier)
        objects[key] = {"isa": isa, **values}
        return key

    def configurations(name, settings):
        config = add(name + ":Debug", "XCBuildConfiguration", name="Debug", buildSettings=settings)
        return add(
            name + ":configs",
            "XCConfigurationList",
            buildConfigurations=[config],
            defaultConfigurationName="Debug",
            defaultConfigurationIsVisible="0",
        )

    info = plistlib.loads((IOS / "Nephos/Info-Debug.plist").read_bytes())
    info.pop("UIApplicationSceneManifest", None)
    (workspace / "Info.plist").write_bytes(plistlib.dumps(info))
    entitlement = workspace / "Simulated.xcent"
    entitlement.write_bytes(plistlib.dumps({"application-identifier": "FAKETEAMID." + BUNDLE}))
    targets, products, files = [], [], []
    for name, is_test in [("NephosUIQualification", False), ("OnboardingUITests", True)]:
        sources = (
            (test_sources or [IOS / "Qualification/QREnrollmentUITests.swift"])
            if is_test
            else sorted(path for path in (IOS / "Nephos").rglob("*.swift") if path.name != "NephosApp.swift")
            + [IOS / "Qualification/UIQualification.swift"]
            + (app_sources or [])
        )
        builds = []
        for path in sources:
            ref = add(
                str(path),
                "PBXFileReference",
                path=str(path),
                sourceTree="<absolute>",
                lastKnownFileType="sourcecode.swift",
            )
            files.append(ref)
            builds.append(add("build:" + str(path), "PBXBuildFile", fileRef=ref))
        product = add(
            name + ":product",
            "PBXFileReference",
            path=name + (".xctest" if is_test else ".app"),
            sourceTree="BUILT_PRODUCTS_DIR",
            explicitFileType="wrapper.cfbundle" if is_test else "wrapper.application",
        )
        products.append(product)
        settings = {
            "PRODUCT_NAME": name,
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE + ".uitests" if is_test else BUNDLE,
            "TARGETED_DEVICE_FAMILY": "1,2",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG UI_QUALIFICATION",
            "CODE_SIGNING_ALLOWED": "NO",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
            "GENERATE_INFOPLIST_FILE": "YES" if is_test else "NO",
        }
        dependencies = []
        if is_test:
            settings.update(TEST_TARGET_NAME="NephosUIQualification", ENABLE_TESTING_SEARCH_PATHS="YES")
            dependencies.append(add("test:dependency", "PBXTargetDependency", target=oid("NephosUIQualification")))
        else:
            settings.update(
                INFOPLIST_FILE=str(workspace / "Info.plist"),
                MARKETING_VERSION="0.1.0",
                CURRENT_PROJECT_VERSION="1",
                ENABLE_DEBUG_DYLIB="NO",
            )
            settings["OTHER_LDFLAGS"] = [
                "-Xlinker",
                "-sectcreate",
                "-Xlinker",
                "__TEXT",
                "-Xlinker",
                "__entitlements",
                "-Xlinker",
                str(entitlement),
            ]
        phase = add(
            name + ":sources",
            "PBXSourcesBuildPhase",
            buildActionMask="2147483647",
            files=builds,
            runOnlyForDeploymentPostprocessing="0",
        )
        targets.append(
            add(
                name,
                "PBXNativeTarget",
                name=name,
                productName=name,
                productReference=product,
                productType="com.apple.product-type.bundle.ui-testing"
                if is_test
                else "com.apple.product-type.application",
                buildConfigurationList=configurations(name, settings),
                buildPhases=[phase],
                buildRules=[],
                dependencies=dependencies,
            )
        )
    products_group = add("products", "PBXGroup", name="Products", sourceTree="<group>", children=products)
    main = add("main", "PBXGroup", sourceTree="<group>", children=files + [products_group])
    root = add(
        "project",
        "PBXProject",
        mainGroup=main,
        productRefGroup=products_group,
        targets=targets,
        projectDirPath="",
        projectRoot="",
        compatibilityVersion="Xcode 14.0",
        attributes={"TargetAttributes": {oid("OnboardingUITests"): {"TestTargetID": oid("NephosUIQualification")}}},
        buildConfigurationList=configurations(
            "project",
            {
                "SDKROOT": "iphoneos",
                "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
                "SWIFT_VERSION": "5.0",
                "CLANG_ENABLE_MODULES": "YES",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            },
        ),
    )
    destination = workspace / "Onboarding.xcodeproj"
    destination.mkdir()
    (destination / "project.pbxproj").write_bytes(
        plistlib.dumps(
            {
                "archiveVersion": "1",
                "objectVersion": "56",
                "classes": {},
                "objects": objects,
                "rootObject": root,
            }
        )
    )
    schemes = destination / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)

    def reference(name, suffix):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid(name)}" BuildableName="{name}.{suffix}" BlueprintName="{name}" ReferencedContainer="container:Onboarding.xcodeproj"/>'

    (schemes / "Onboarding.xcscheme").write_text(
        '<Scheme version="1.3"><BuildAction buildImplicitDependencies="YES"><BuildActionEntries>'
        '<BuildActionEntry buildForTesting="YES">'
        + reference("OnboardingUITests", "xctest")
        + "</BuildActionEntry></BuildActionEntries></BuildAction>"
        '<TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO">'
        + reference("OnboardingUITests", "xctest")
        + "</TestableReference></Testables></TestAction></Scheme>"
    )
    return destination
