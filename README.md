# Studio Capture

Apple Silicon Mac向けの、画面と内部音声を同時に収録するSwiftUIアプリです。Logic Proなどの操作画面の録画を想定した初期開発版です。

## 機能

- ディスプレイ全体または指定アプリの画面収録
- ScreenCaptureKitによるMac内部／アプリ出力音声の取得（外部ループバック機器不要）
- マイク・カメラ・マウスカーソルの個別ON/OFF（録画開始前）
- カメラ映像を保存動画の右下に合成
- 長辺最大1920px・30fps、H.264/AACのMP4保存
- 内部音声とマイクの両方を使う場合は、停止時に音声を混合
- 日本語UI、大きな開始・停止ボタン

## 動作環境とビルド

Apple Silicon、macOS 15以降。Xcode 26.2 / Swift 6.2.3でビルド確認済み。外部パッケージは不要です。

`StudioCapture.xcodeproj` をXcodeで開き、スキーム `StudioCapture`、実行先 `My Mac` を選択して実行してください。

```sh
xcodebuild -project StudioCapture.xcodeproj -scheme StudioCapture \
  -configuration Release -derivedDataPath build build
```

生成されるアプリは `build/Build/Products/Release/StudioCapture.app` です。ローカル実行用署名で、Developer ID署名・公証はしていません。

## 使い方

1. Logic Proなど、収録対象のアプリを表示します。
2. 「画面一覧を読み込む / 更新」を押します。初回はmacOSの画面収録権限を許可し、必要ならアプリを開き直してください。
3. ディスプレイと収録対象を選びます。アプリ限定時の背景は黒になります。
4. 内部音声・マイク・カメラ・カーソルを設定します。マイクとカメラはONの場合だけ権限が必要です。
5. 「録画を開始」で保存先を選び、「停止して保存」でMP4を書き出します。

マイクは標準入力デバイス、カメラは標準カメラを使用します。カメラは保存動画に合成され、アプリ内の画面プレビューには表示されません。2音源を混合する際はそれぞれ音量を半分にします。既存ファイルは上書きしません。

## 検証状況・制限

2026年10月4日にアプリ起動、UIのマイク切替、合成素材による4通りの保存（無音／内部音声相当／マイク相当／両方）を確認しました。各動画は2秒・60フレームで、音声成分、44.1→48kHz変換、カメラ枠の有無も確認しています。

**実際のLogic Pro出力、実カメラ・マイクの同期、初回権限操作、長時間録画は未検証です。** 特に外部オーディオインターフェイス利用時は、短い録画で音と映像を確認してください。一時MOVとMP4用の空き容量が必要です。

## ソース構成

- `StudioCapture/RecorderApp.swift`: UI・権限・開始／停止
- `StudioCapture/CaptureEngine.swift`: 画面・音声・カメラの取得
- `StudioCapture/MediaWriter.swift`: 映像合成、書き込み、音声混合
- `Tests/MediaTests.swift`: 合成素材を使った保存テスト
- `Tools/generate_project.py`: Xcodeプロジェクトの再生成（通常は不要）

テストは `zsh Tools/run_tests.sh` で実行できます。画面・カメラ・マイクへアクセスせず、合成素材のみを使用します。Xcodeのコマンドラインツールが必要です。
