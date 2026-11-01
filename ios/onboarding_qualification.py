#!/usr/bin/env python3
"""Drive production onboarding controls in an isolated XCTest app against real HTTPS."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

from generate_project import oid

IOS = Path(__file__).resolve().parent
BUNDLE = "app.nephos.ui-qualification"


def project(workspace):
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
            [IOS / "Qualification/OnboardingUITests.swift"]
            if is_test
            else sorted(path for path in (IOS / "Nephos").rglob("*.swift") if path.name != "NephosApp.swift")
            + [IOS / "Qualification/UIQualification.swift"]
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--base-url", default="")
    parser.add_argument("--certificate-error-url", default="")
    parser.add_argument(
        "--signin-email", default="", help="Enabled known fixture account for the email-first PIN check."
    )
    parser.add_argument(
        "--backup", action="store_true", help="Exercise foreground retries and backup UI with controlled responses."
    )
    parser.add_argument("--discovery", action="store_true", help="Also require the base URL's real LAN announcement.")
    args = parser.parse_args()
    if not args.backup and (not args.base_url or not args.certificate_error_url or not args.signin_email):
        parser.error("Onboarding checks require --base-url, --certificate-error-url and --signin-email.")
    scratch = IOS / ".test-work"
    scratch.mkdir(exist_ok=True)
    (IOS / ".logs").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="onboarding-ui-", dir=scratch) as directory:
        workspace = Path(directory)
        destination = project(workspace)
        common = [
            "xcodebuild",
            "-quiet",
            "-project",
            str(destination),
            "-scheme",
            "Onboarding",
            "-sdk",
            "iphonesimulator",
            "-destination",
            "id=" + args.simulator,
            "-derivedDataPath",
            str(workspace / "DerivedData"),
        ]
        try:
            subprocess.run(common + ["build-for-testing"], check=True)
            subprocess.run(
                [
                    "codesign",
                    "--force",
                    "--sign",
                    "-",
                    "--identifier",
                    BUNDLE,
                    str(workspace / "DerivedData/Build/Products/Debug-iphonesimulator/NephosUIQualification.app"),
                ],
                check=True,
            )
            runfile = next((workspace / "DerivedData/Build/Products").glob("*.xctestrun"))
            run = plistlib.loads(runfile.read_bytes())
            targets = (
                [target for configuration in run["TestConfigurations"] for target in configuration["TestTargets"]]
                if "TestConfigurations" in run
                else [target for target in run.values() if isinstance(target, dict) and "TestBundlePath" in target]
            )
            if not targets:
                raise RuntimeError("Xcode did not generate any executable UI test targets.")
            for target in targets:
                target.setdefault("EnvironmentVariables", {}).update(
                    {
                        "NEPHOS_UI_BASE_URL": args.base_url.rstrip("/"),
                        "NEPHOS_UI_BAD_CERT_URL": args.certificate_error_url.rstrip("/"),
                        "NEPHOS_UI_SIGNIN_EMAIL": args.signin_email,
                        "NEPHOS_UI_DISCOVERY": "1" if args.discovery else "0",
                    }
                )
            runfile.write_bytes(plistlib.dumps(run))
            subprocess.run(
                [
                    "xcodebuild",
                    "-quiet",
                    "test-without-building",
                    "-only-testing:OnboardingUITests/" + ("BackupUITests" if args.backup else "OnboardingUITests"),
                    "-xctestrun",
                    str(runfile),
                    "-destination",
                    "id=" + args.simulator,
                    "-parallel-testing-enabled",
                    "NO",
                    "-resultBundlePath",
                    str(IOS / ".logs" / (workspace.name + ".xcresult")),
                ],
                check=True,
            )
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, BUNDLE], check=False)
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, BUNDLE + ".uitests.xctrunner"], check=False)


if __name__ == "__main__":
    main()
