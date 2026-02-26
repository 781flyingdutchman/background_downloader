# Android Environment Setup

This project requires the Android SDK to be installed and configured. Since the environment might not have it pre-installed, follow these steps to set it up (tested on Linux/Ubuntu).

## 1. Install Android SDK Command-line Tools

Create a directory for the SDK and download the command-line tools:

```bash
mkdir -p ~/android-sdk/cmdline-tools/latest
wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O ~/cmdline-tools.zip
unzip -q ~/cmdline-tools.zip -d ~/android-sdk/cmdline-tools/
mv ~/android-sdk/cmdline-tools/cmdline-tools/* ~/android-sdk/cmdline-tools/latest/
rmdir ~/android-sdk/cmdline-tools/cmdline-tools
rm ~/cmdline-tools.zip
```

## 2. Configure Environment Variables

Set `ANDROID_HOME` and update `PATH`:

```bash
export ANDROID_HOME=~/android-sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$PATH
```

## 3. Accept Licenses and Install SDK Components

Accept licenses:

```bash
yes | sdkmanager --licenses
```

Install required platforms and build tools (adjust versions as needed, e.g., for compileSdk 36):

```bash
sdkmanager "platform-tools" "platforms;android-36" "build-tools;35.0.0"
```

## 4. Configure Flutter

Tell Flutter where the Android SDK is located:

```bash
flutter config --android-sdk ~/android-sdk
```

Verify the setup:

```bash
flutter doctor
```

## 5. Restore Gradle Wrapper (if missing)

If `gradlew` is missing in `example/android`:

```bash
cd example
flutter create .
```
Note: This might create `.kts` build files if you are on a newer Flutter version. If the project uses Groovy DSL (`build.gradle`), you may want to delete the generated `.kts` files to avoid conflicts.

## 6. Run Lint

To run Android Lint on the plugin:

```bash
cd example/android
./gradlew :background_downloader:lint
```

The report will be available in `example/build/background_downloader/reports/lint-results-debug.html`.
