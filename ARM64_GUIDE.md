# IrScrutinizer on ARM64 (aarch64) — Fedora & Debian Guide

This document describes how to compile, package, install, and run **IrScrutinizer** on **Fedora** and **Debian** (and derived distributions like Ubuntu, Raspberry Pi OS 64-bit, and Fedora Asahi Remix) for 64-bit ARM (`aarch64` / `arm64`), with full compatibility for both **4K and 16K kernel page sizes**.

---

## 1. Page Size Compatibility (4K & 16K)

ARM64 Linux kernels can be configured with different memory page sizes:
* **4 KB pages**: Default in Debian, Ubuntu, standard Fedora, and Raspberry Pi OS (64-bit).
* **16 KB pages**: Default in Fedora Asahi Remix (Apple Silicon), modern Android kernels, and customized embedded configurations.
* **64 KB pages**: Used by some enterprise server kernels.

If a native ELF shared library (`.so`) is compiled with standard 4K alignment, loading it on a 16K or 64K page size kernel fails with `LOAD segment ... not aligned to page size` or `cannot change memory protections: Permission denied`.

In IrScrutinizer:
* `libdevslashlirc.so` (JNI library for `/dev/lirc` access) is built with 64KB ELF segment alignment (`-Wl,-z,max-page-size=65536`).
* `libNRJavaSerial.so` (JNI library for serial communication) is aligned to 64KB.
* Native libraries are organized in `native/Linux-aarch64/` and `native/Linux-arm64/` and resolved dynamically by `GuiMain.java` and `HarcHardware`.
* As a result, the same binary and packages run seamlessly on **4K, 16K, and 64K page kernels**.

---

## 2. Installing Prebuilt Packages

### Fedora / RHEL / Asahi (`aarch64`)
To install the RPM package:
```bash
sudo dnf install ./target/packages/irscrutinizer-2.4.3-1.fc44.aarch64.rpm
```
*(Or use `rpm -ivh ./target/packages/irscrutinizer-2.4.3-1.fc44.aarch64.rpm`)*

### Debian / Ubuntu / Raspberry Pi OS (`arm64`)
To install the Debian package:
```bash
sudo apt install ./target/packages/irscrutinizer_2.4.3-1_arm64.deb
```
*(Or use `sudo dpkg -i ./target/packages/irscrutinizer_2.4.3-1_arm64.deb` followed by `sudo apt-get install -f`)*

### Generic Binary Distribution (`.zip`)
If you prefer manual installation without a package manager:
```bash
sudo mkdir -p /usr/local/share/irscrutinizer
sudo unzip -o target/IrScrutinizer-*-bin.zip -d /usr/local/share/irscrutinizer
cd /usr/local/share/irscrutinizer
sudo ./setup-irscrutinizer.sh
```

---

## 3. Compiling from Source

### Automated Build & Test (`build.sh`) — Recommended

IrScrutinizer provides an automated build script `build.sh` in the repository root. It handles dependency resolution, native library verification, compilation, test execution, packaging, and package generation with a single command:

```bash
# Compile, execute test suite, and package fat JAR & binary distribution:
./build.sh

# Build everything including Fedora (.rpm) and Debian (.deb) packages:
./build.sh --packages

# Run unit and integration tests only:
./build.sh --test-only

# Rebuild all dependencies and IrScrutinizer:
./build.sh --deps
```

---

### Step 3.1: Install Build Dependencies

#### On Fedora / Asahi Linux:
```bash
sudo dnf install -y \
    java-21-openjdk-devel \
    maven \
    ant \
    gcc \
    gcc-c++ \
    git \
    dos2unix \
    icoutils \
    genisoimage \
    libusal \
    rpm-build
```

#### On Debian / Ubuntu:
```bash
sudo apt update
sudo apt install -y \
    default-jdk \
    maven \
    ant \
    build-essential \
    g++ \
    git \
    dos2unix \
    icoutils \
    genisoimage \
    dpkg-dev
```

---

### Step 3.2: Build Dependent Projects

IrScrutinizer depends on sibling `harctoolbox` projects. In the parent directory containing `IrScrutinizer`:

1. **DevSlashLirc** (Linux `/dev/lirc` JNI library):
   ```bash
   git clone https://github.com/bengtmartensson/DevSlashLirc.git
   cd DevSlashLirc
   mvn compile
   
   # Build the C++ JNI library with 64KB page alignment
   cd src/main/c++
   mkdir -p ../../../target/generated-sources/c++/org/harctoolbox/devslashlirc
   javac -h ../../../target/generated-sources/c++/org/harctoolbox/devslashlirc \
       -classpath ../../../target/classes \
       ../java/org/harctoolbox/devslashlirc/Mode2LircDevice.java \
       ../java/org/harctoolbox/devslashlirc/LircCodeLircDevice.java \
       ../java/org/harctoolbox/devslashlirc/LircDevice.java
   make clean
   make JAVA_INCLUDE="${JAVA_HOME}/include" CXXFLAGS="-Wl,-z,max-page-size=65536"
   
   cd ../../..
   mvn install -Dmaven.test.skip=true
   cd ..
   ```

2. **IrpTransmogrifier**:
   ```bash
   git clone https://github.com/bengtmartensson/IrpTransmogrifier.git
   cd IrpTransmogrifier
   mvn install -Dmaven.test.skip=true
   cd ..
   ```

3. **RemoteLocator**:
   ```bash
   git clone https://github.com/bengtmartensson/RemoteLocator.git
   cd RemoteLocator
   mvn install -Dmaven.test.skip=true
   cd ..
   ```

4. **HarcHardware**:
   ```bash
   git clone https://github.com/bengtmartensson/HarcHardware.git
   cd HarcHardware
   mvn install -Dmaven.test.skip=true
   cd ..
   ```

5. **Tonto**:
   ```bash
   git clone https://github.com/stewartoallen/tonto.git
   cd tonto
   git checkout be1657a
   sed -i -e '/signjar/d' -e 's/<javac/<javac source="1.8" target="1.8"/' build.xml
   ant all
   mvn install:install-file \
       -DgroupId=com.mrallen \
       -DartifactId=tonto \
       -Dversion=1.44 \
       -Dpackaging=jar \
       -Dfile=jars/tonto.jar
   cd ..
   ```

---

### Step 3.3: Build IrScrutinizer

In the `IrScrutinizer` repository directory:

```bash
# 1. Ensure native libraries are present in native/Linux-aarch64 and native/Linux-arm64
mkdir -p native/Linux-aarch64 native/Linux-arm64
cp ../DevSlashLirc/src/main/c++/libdevslashlirc.so native/Linux-aarch64/
# Copy ARM64 NRJavaSerial library (extracted from nrjavaserial-5.2.1.jar)
unzip -p ~/.m2/repository/com/neuronrobotics/nrjavaserial/5.2.1/nrjavaserial-5.2.1.jar \
    native/linux/ARM_64/libNRJavaSerialv8.so > native/Linux-aarch64/libNRJavaSerial.so
chmod 755 native/Linux-aarch64/*
cp native/Linux-aarch64/* native/Linux-arm64/

# 2. Compile and package with Maven
mvn package -Dmaven.test.skip=true
```

This generates:
* `target/IrScrutinizer-*-jar-with-dependencies.jar` (Fat executable JAR)
* `target/IrScrutinizer-*-bin.zip` (Binary distribution archive)

---

### Step 3.4: Build Fedora RPM and Debian DEB Packages

Run the packaging script to generate both distribution packages:
```bash
./tools/mk-linux-packages.sh
```

Packages are output to `target/packages/`:
* `target/packages/irscrutinizer-2.4.3-1.<dist>.aarch64.rpm`
* `target/packages/irscrutinizer_2.4.3-1_arm64.deb`

---

## 4. Post-Installation & User Permissions

On Linux, accessing serial transceivers, Arduino, IrToy, and `/dev/lirc` hardware requires membership in the appropriate hardware device groups:

```bash
sudo usermod -aG dialout,lock,lirc $USER
```
*(Log out and log back in for group changes to take effect).*

---

## 5. Running IrScrutinizer

### Graphical User Interface (GUI):
```bash
irscrutinizer
```
Or launch **IrScrutinizer** from your desktop application menu.

### Command-Line Interface Tools:
The package provides symlinks in `/usr/bin` for all bundled CLI utilities:
* `irptransmogrifier [options]` — Protocol rendering and code generation
* `harchardware [options]` — Direct command-line hardware transmission/reception
* `HexCalculator` — Hexadecimal calculator
* `TimeFrequencyCalculator` — Infrared timing and frequency calculator
* `AmxBeaconListenerPanel` — AMX beacon listener
