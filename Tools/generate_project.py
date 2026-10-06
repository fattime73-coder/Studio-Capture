#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project (Python standard library only)."""
import hashlib, pathlib, plistlib
root = pathlib.Path(__file__).resolve().parent.parent

def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def quote(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(key, value):
    objects.append(f'{ident(key)} = {{ {value} }};')
    return ident(key)
def array(values): return '(' + ', '.join(values) + ',)'

def configs(key, values):
    ids = []
    for mode in ['Debug', 'Release']:
        settings = dict(values)
        settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
        settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'
        if mode == 'Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(obj(key + mode, 'isa = XCBuildConfiguration; name = ' + mode + '; buildSettings = {' + ''.join(f'{k} = {quote(v)};' for k,v in settings.items()) + '};'))
    return obj(key + 'configs', 'isa = XCConfigurationList; buildConfigurations = ' + array(ids) + '; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

targets=[]; groups=[]; products=[]
for name in ['StudioCapture']:
    files=sorted((root/name).glob('*.swift')) + sorted((root/name).glob('*.wav'))
    children=[]; sources=[]; resources=[]
    for path in files:
        kind = 'sourcecode.swift' if path.suffix=='.swift' else 'audio.wav'
        ref=obj(str(path.relative_to(root))+'ref', f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path.name)}; sourceTree = "<group>";')
        children.append(ref)
        build=obj(str(path.relative_to(root))+'build', f'isa = PBXBuildFile; fileRef = {ref};')
        (sources if path.suffix=='.swift' else resources).append(build)
    groups.append(obj(name+'group',f'isa = PBXGroup; children = {array(children)}; path = {quote(name)}; sourceTree = "<group>";'))
    product=obj(name+'product',f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    phases=[]
    for phase, isa, entries in [('sources','PBXSourcesBuildPhase',sources),('resources','PBXResourcesBuildPhase',resources),('frameworks','PBXFrameworksBuildPhase',[])]:
        # Empty PBX lists use () rather than (,).
        entries_text=array(entries) if entries else '()'
        phases.append(obj(name+phase,f'isa = {isa}; buildActionMask = 2147483647; files = {entries_text}; runOnlyForDeploymentPostprocessing = 0;'))
    info={'CFBundleDevelopmentRegion':'ja','CFBundleExecutable':'$(EXECUTABLE_NAME)', 'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleInfoDictionaryVersion':'6.0','CFBundleName':name,'CFBundleDisplayName': 'Studio Capture',
        'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1',
        'LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,
        'NSMicrophoneUsageDescription':'選択した場合だけ、マイクの音声を動画に収録します。'}
    if name=='StudioCapture':
        info.update(NSCameraUsageDescription='選択した場合だけ、カメラ映像を録画の右下に重ねます。',NSScreenCaptureUsageDescription='選択した画面とMac内部の音声を動画に収録します。',NSAudioCaptureUsageDescription='Macのアプリ出力音声を動画と一緒に収録します。')
    (root/name/'Info.plist').write_bytes(plistlib.dumps(info))
    config=configs(name,{'PRODUCT_NAME':name,'PRODUCT_BUNDLE_IDENTIFIER':'local.musicapps.'+name.lower(),
        'INFOPLIST_FILE':name+'/Info.plist','GENERATE_INFOPLIST_FILE':'NO','CODE_SIGN_STYLE':'Manual','CODE_SIGN_IDENTITY':'-',
        'ENABLE_HARDENED_RUNTIME':'NO','ENABLE_APP_SANDBOX':'NO','SWIFT_VERSION':'5.0','MACOSX_DEPLOYMENT_TARGET':'15.0',
        'ARCHS':'arm64','SUPPORTED_PLATFORMS':'macosx','SDKROOT':'macosx','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
    targets.append(obj(name+'target',f'isa = PBXNativeTarget; buildConfigurationList = {config}; buildPhases = {array(phases)}; buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.application";'))
productgroup=obj('products',f'isa = PBXGroup; children = {array(products)}; name = Products; sourceTree = "<group>";')
main=obj('main',f'isa = PBXGroup; children = {array(groups+[productgroup])}; sourceTree = "<group>";')
projectconfig=configs('project',{'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','MACOSX_DEPLOYMENT_TARGET':'15.0','SDKROOT':'macosx','ARCHS':'arm64','ENABLE_USER_SCRIPT_SANDBOXING':'YES'})
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {projectconfig}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ja; hasScannedForEncodings = 0; knownRegions = (ja,en,Base); mainGroup = {main}; productRefGroup = {productgroup}; projectDirPath = ""; projectRoot = ""; targets = {array(targets)};')
projectdir=root/'StudioCapture.xcodeproj'; projectdir.mkdir(exist_ok=True)
(projectdir/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
schemes=projectdir/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
for name in ['StudioCapture']:
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name+"target")}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:StudioCapture.xcodeproj"/>'
    (schemes/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Created StudioCapture.xcodeproj with one app target.')
