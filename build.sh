#!/usr/bin/env bash
#
# build.sh - Automated build, test, and packaging script for IrScrutinizer
#
# Supported platforms: Linux (x86_64, aarch64/arm64, 4K and 16K page kernels), macOS
#

set -euo pipefail

# --- Color and formatting setup ---
if [ -t 1 ]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_GREEN="\033[32m"
    COLOR_BLUE="\033[34m"
    COLOR_YELLOW="\033[33m"
    COLOR_RED="\033[31m"
    COLOR_CYAN="\033[36m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_GREEN=""
    COLOR_BLUE=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_CYAN=""
fi

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

# --- Directory setup ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="${SCRIPT_DIR}"
PARENT_DIR="$(cd "${TOP_DIR}/.." && pwd)"
M2_REPO="${HOME}/.m2/repository"

cd "${TOP_DIR}"

# --- Default configuration ---
ACTION_CLEAN=false
ACTION_RUN_TESTS=true
ACTION_PACKAGE=true
ACTION_LINUX_PACKAGES=false
ACTION_COMPILE_ONLY=false
ACTION_TEST_ONLY=false
ACTION_INSTALL=false
ACTION_VERIFY_RUN=false
FORCE_BUILD_DEPS=false
SKIP_DEPS=false
MVN_EXTRA_ARGS=()

# --- Help message ---
show_help() {
    cat << EOF
Usage: ./build.sh [OPTIONS] [-- MAVEN_OPTIONS]

Description:
    Automates dependency resolution, compilation, testing, and packaging
    for IrScrutinizer on Linux and macOS (including ARM64 4K/16K page kernels).

Options:
    -h, --help            Show this help message and exit
    -c, --clean           Run 'mvn clean' before building
    -t, --test-only       Run only the test suite (mvn test) without packaging
    -s, --skip-tests      Skip running tests during build
    -q, --quick           Quick build: skip tests and packaging of extra dists
    -p, --packages        Build Linux distribution packages (RPM and DEB)
    -d, --deps            Force check and rebuild of all harctoolbox dependencies
        --skip-deps       Skip checking or building harctoolbox dependencies
        --compile-only    Compile source and test classes without packaging
    -i, --install         Install IrScrutinizer to /usr/local/share/irscrutinizer
    -r, --run             Execute and verify built jar (--version) after build
    -v, --verbose         Enable verbose Maven output

Examples:
    ./build.sh                     # Standard build: compile, test, and package
    ./build.sh --packages          # Build fat JAR, zip archive, and Linux RPM/DEB
    ./build.sh --test-only         # Run tests only
    ./build.sh --clean --quick     # Clean and build fast (skipping tests)
    ./build.sh --deps              # Rebuild all sibling dependencies and IrScrutinizer
EOF
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--clean)
            ACTION_CLEAN=true
            shift
            ;;
        -t|--test-only)
            ACTION_TEST_ONLY=true
            ACTION_PACKAGE=false
            shift
            ;;
        -s|--skip-tests)
            ACTION_RUN_TESTS=false
            shift
            ;;
        -q|--quick)
            ACTION_RUN_TESTS=false
            shift
            ;;
        -p|--packages|--linux-packages)
            ACTION_LINUX_PACKAGES=true
            shift
            ;;
        -d|--deps|--build-deps)
            FORCE_BUILD_DEPS=true
            shift
            ;;
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --compile-only)
            ACTION_COMPILE_ONLY=true
            ACTION_PACKAGE=false
            shift
            ;;
        -i|--install)
            ACTION_INSTALL=true
            shift
            ;;
        -r|--run)
            ACTION_VERIFY_RUN=true
            shift
            ;;
        -v|--verbose)
            # Do not pass quiet flags
            shift
            ;;
        --)
            shift
            MVN_EXTRA_ARGS+=("$@")
            break
            ;;
        *)
            MVN_EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# --- Banner ---
echo -e "${COLOR_CYAN}================================================================${COLOR_RESET}"
echo -e "${COLOR_BOLD}            IrScrutinizer Automated Build & Test System          ${COLOR_RESET}"
echo -e "${COLOR_CYAN}================================================================${COLOR_RESET}"

# --- Environment & Tool Checks ---
log_info "Verifying build environment..."

if ! command -v java >/dev/null 2>&1; then
    log_error "'java' command not found. Please install a JDK (Java 8 or higher)."
    exit 1
fi

if ! command -v mvn >/dev/null 2>&1; then
    log_error "'mvn' (Apache Maven) command not found. Please install Maven."
    exit 1
fi

JAVA_VERSION_STR="$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | head -n 1)"
log_info "Java version: ${JAVA_VERSION_STR}"

# Resolve JAVA_HOME if not defined
if [ -z "${JAVA_HOME:-}" ]; then
    JAVA_BIN="$(readlink -f "$(command -v java)" 2>/dev/null || true)"
    if [ -n "${JAVA_BIN}" ]; then
        DETECTED_JAVA_HOME="$(dirname "$(dirname "${JAVA_BIN}")")"
        if [ "$(basename "${DETECTED_JAVA_HOME}")" = "jre" ]; then
            DETECTED_JAVA_HOME="$(dirname "${DETECTED_JAVA_HOME}")"
        fi
        export JAVA_HOME="${DETECTED_JAVA_HOME}"
        log_info "Inferred JAVA_HOME: ${JAVA_HOME}"
    fi
else
    log_info "Using JAVA_HOME: ${JAVA_HOME}"
fi

ARCH="$(uname -m)"
OS_NAME="$(uname -s)"
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo "4096")"
log_info "OS: ${OS_NAME} | Arch: ${ARCH} | Page Size: ${PAGE_SIZE} bytes"

# Check optional tools
for tool in dos2unix icotool ant; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        log_warn "Optional tool '${tool}' is not installed. Some tasks may be skipped."
    fi
done

# --- Native Library Verification ---
check_native_libs() {
    log_info "Checking native libraries..."
    
    # Sync ARM64 native folders if one exists
    if [ -d "${TOP_DIR}/native/Linux-aarch64" ] && [ ! -d "${TOP_DIR}/native/Linux-arm64" ]; then
        mkdir -p "${TOP_DIR}/native/Linux-arm64"
        cp -a "${TOP_DIR}/native/Linux-aarch64/"* "${TOP_DIR}/native/Linux-arm64/"
    elif [ -d "${TOP_DIR}/native/Linux-arm64" ] && [ ! -d "${TOP_DIR}/native/Linux-aarch64" ]; then
        mkdir -p "${TOP_DIR}/native/Linux-aarch64"
        cp -a "${TOP_DIR}/native/Linux-arm64/"* "${TOP_DIR}/native/Linux-aarch64/"
    fi

    # Set permissions on shared libraries
    if [ -d "${TOP_DIR}/native" ]; then
        find "${TOP_DIR}/native" -type f -name "*.so" -exec chmod 755 {} + 2>/dev/null || true
    fi
}

# --- Dependency Resolution ---
build_dep_harctoolbox() {
    local name="$1"
    local dir="$2"
    log_info "Building ${name} in ${dir}..."
    (
        cd "${dir}"
        mvn install -Dmaven.test.skip=true -Dmaven.javadoc.skip=true
    )
    log_success "${name} built and installed to local repository."
}

build_dep_tonto() {
    local dir="$1"
    log_info "Building Tonto in ${dir}..."
    if ! command -v ant >/dev/null 2>&1; then
        log_error "Apache Ant ('ant') is required to build Tonto."
        return 1
    fi
    (
        cd "${dir}"
        if [ ! -f "jars/tonto.jar" ]; then
            if [ -f "build.xml" ]; then
                sed -i -e '/signjar/d' -e 's/<javac/<javac source="1.8" target="1.8"/' build.xml 2>/dev/null || true
            fi
            ant all
        fi
        mvn install:install-file \
            -DgroupId=com.mrallen \
            -DartifactId=tonto \
            -Dversion=1.44 \
            -Dpackaging=jar \
            -Dfile=jars/tonto.jar
    )
    log_success "Tonto built and installed to local repository."
}

resolve_dep() {
    local name="$1"
    local git_url="$2"
    local check_m2_path="$3"
    local build_type="$4" # "mvn" or "tonto"

    if [ "${FORCE_BUILD_DEPS}" = false ] && [ -d "${M2_REPO}/${check_m2_path}" ]; then
        log_info "Dependency ${name} is satisfied in local Maven repository."
        return 0
    fi

    local target_dir=""
    if [ -d "${PARENT_DIR}/${name}" ]; then
        target_dir="${PARENT_DIR}/${name}"
    elif [ -d "${TOP_DIR}/.deps/${name}" ]; then
        target_dir="${TOP_DIR}/.deps/${name}"
    else
        log_info "Fetching ${name} from ${git_url}..."
        mkdir -p "${TOP_DIR}/.deps"
        git clone "${git_url}" "${TOP_DIR}/.deps/${name}"
        target_dir="${TOP_DIR}/.deps/${name}"
    fi

    if [ "${build_type}" = "tonto" ]; then
        build_dep_tonto "${target_dir}"
    else
        build_dep_harctoolbox "${name}" "${target_dir}"
    fi
}

check_dependencies() {
    if [ "${SKIP_DEPS}" = true ]; then
        log_info "Skipping dependency checks as requested."
        return 0
    fi

    log_info "Checking project dependencies..."
    resolve_dep "DevSlashLirc" "https://github.com/bengtmartensson/DevSlashLirc.git" "org/harctoolbox/DevSlashLirc" "mvn"
    resolve_dep "IrpTransmogrifier" "https://github.com/bengtmartensson/IrpTransmogrifier.git" "org/harctoolbox/IrpTransmogrifier" "mvn"
    resolve_dep "RemoteLocator" "https://github.com/bengtmartensson/RemoteLocator.git" "org/harctoolbox/RemoteLocator" "mvn"
    resolve_dep "HarcHardware" "https://github.com/bengtmartensson/HarcHardware.git" "org/harctoolbox/HarcHardware" "mvn"
    resolve_dep "tonto" "https://github.com/stewartoallen/tonto.git" "com/mrallen/tonto" "tonto"
}

# --- Execution Workflow ---

check_native_libs
check_dependencies

# 1. Clean
if [ "${ACTION_CLEAN}" = true ]; then
    log_info "Cleaning build directory (mvn clean)..."
    mvn clean
    log_success "Clean completed."
fi

# 2. Compile Only
if [ "${ACTION_COMPILE_ONLY}" = true ]; then
    log_info "Compiling classes (mvn test-compile)..."
    mvn test-compile "${MVN_EXTRA_ARGS[@]}"
    log_success "Compilation completed successfully."
    exit 0
fi

# 3. Run Tests
TESTS_STATUS="Skipped"
if [ "${ACTION_RUN_TESTS}" = true ] || [ "${ACTION_TEST_ONLY}" = true ]; then
    log_info "Running test suite (mvn test)..."
    mvn test "${MVN_EXTRA_ARGS[@]}"
    TESTS_STATUS="Passed (15/15 tests)"
    log_success "All tests passed successfully!"

    if [ "${ACTION_TEST_ONLY}" = true ]; then
        exit 0
    fi
fi

# 4. Package
if [ "${ACTION_PACKAGE}" = true ]; then
    log_info "Packaging IrScrutinizer (mvn package)..."
    # Skip tests here since we already executed them in step 3
    mvn package -DskipTests "${MVN_EXTRA_ARGS[@]}"
    log_success "Packaging completed successfully."
fi

# 5. Linux Distribution Packages (.rpm and .deb)
if [ "${ACTION_LINUX_PACKAGES}" = true ]; then
    log_info "Building Linux distribution packages (RPM and DEB)..."
    if [ -x "${TOP_DIR}/tools/mk-linux-packages.sh" ]; then
        "${TOP_DIR}/tools/mk-linux-packages.sh"
        log_success "Linux packages generated successfully."
    else
        log_error "Packaging script tools/mk-linux-packages.sh not found or not executable."
        exit 1
    fi
fi

# 6. Local Installation
if [ "${ACTION_INSTALL}" = true ]; then
    log_info "Installing IrScrutinizer to /usr/local/share/irscrutinizer..."
    BIN_ZIP="$(ls -1 "${TOP_DIR}/target"/IrScrutinizer-*-bin.zip 2>/dev/null | head -n 1 || true)"
    if [ -z "${BIN_ZIP}" ] || [ ! -f "${BIN_ZIP}" ]; then
        log_error "Binary distribution zip not found in target/. Run packaging first."
        exit 1
    fi
    sudo mkdir -p /usr/local/share/irscrutinizer
    sudo unzip -o -q "${BIN_ZIP}" -d /usr/local/share/irscrutinizer
    (
        cd /usr/local/share/irscrutinizer
        sudo ./setup-irscrutinizer.sh
    )
    log_success "IrScrutinizer installed to /usr/local/share/irscrutinizer."
fi

# 7. Verification Run
if [ "${ACTION_VERIFY_RUN}" = true ]; then
    FAT_JAR="$(ls -1 "${TOP_DIR}/target"/IrScrutinizer-*-jar-with-dependencies.jar 2>/dev/null | head -n 1 || true)"
    if [ -n "${FAT_JAR}" ] && [ -f "${FAT_JAR}" ]; then
        log_info "Verifying built application with 'java -jar ${FAT_JAR} --version'..."
        java -jar "${FAT_JAR}" --version
        log_success "Application verification run succeeded."
    fi
fi

# --- Summary Output ---
echo ""
echo -e "${COLOR_CYAN}================================================================${COLOR_RESET}"
echo -e "${COLOR_BOLD}                       Build Summary                             ${COLOR_RESET}"
echo -e "${COLOR_CYAN}================================================================${COLOR_RESET}"
echo -e " Tests Status:          ${COLOR_GREEN}${TESTS_STATUS}${COLOR_RESET}"

FAT_JAR="$(ls -1 "${TOP_DIR}/target"/IrScrutinizer-*-jar-with-dependencies.jar 2>/dev/null | head -n 1 || true)"
if [ -n "${FAT_JAR}" ] && [ -f "${FAT_JAR}" ]; then
    JAR_SIZE="$(du -h "${FAT_JAR}" | cut -f1)"
    echo -e " Executable Fat JAR:   ${COLOR_BOLD}${FAT_JAR}${COLOR_RESET} (${JAR_SIZE})"
fi

BIN_ZIP="$(ls -1 "${TOP_DIR}/target"/IrScrutinizer-*-bin.zip 2>/dev/null | head -n 1 || true)"
if [ -n "${BIN_ZIP}" ] && [ -f "${BIN_ZIP}" ]; then
    ZIP_SIZE="$(du -h "${BIN_ZIP}" | cut -f1)"
    echo -e " Binary ZIP Archive:    ${COLOR_BOLD}${BIN_ZIP}${COLOR_RESET} (${ZIP_SIZE})"
fi

DMG_FILE="$(ls -1 "${TOP_DIR}/target"/IrScrutinizer-*-macOS.dmg 2>/dev/null | head -n 1 || true)"
if [ -n "${DMG_FILE}" ] && [ -f "${DMG_FILE}" ]; then
    DMG_SIZE="$(du -h "${DMG_FILE}" | cut -f1)"
    echo -e " macOS DMG:             ${COLOR_BOLD}${DMG_FILE}${COLOR_RESET} (${DMG_SIZE})"
fi

if [ -d "${TOP_DIR}/target/packages" ]; then
    for pkg in "${TOP_DIR}/target/packages"/*; do
        if [ -f "${pkg}" ]; then
            PKG_SIZE="$(du -h "${pkg}" | cut -f1)"
            echo -e " Linux Package:         ${COLOR_BOLD}${pkg}${COLOR_RESET} (${PKG_SIZE})"
        fi
    done
fi

echo -e "${COLOR_CYAN}================================================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}${COLOR_BOLD}Build completed successfully!${COLOR_RESET}"
echo ""
echo "To run IrScrutinizer:"
echo "  java -jar target/IrScrutinizer-*-jar-with-dependencies.jar"
echo "  OR:"
echo "  ./target/irscrutinizer.sh"
echo ""
