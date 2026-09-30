#!/bin/bash
set -euo pipefail

# Build Fedora RPM and Debian DEB packages for ARM64 (aarch64)
# Compatible with both 4K and 16K page kernels.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${TOP_DIR}"

VERSION="2.4.3"
RELEASE="1"
PKG_NAME="irscrutinizer"
DIST_DIR="${TOP_DIR}/target/packages"

echo "=== Creating ARM64 Fedora (.rpm) and Debian (.deb) packages ==="
mkdir -p "${DIST_DIR}"

# 1. Prepare Staging Root
STAGING_DIR="${TOP_DIR}/target/staging-pkg"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/usr/share/irscrutinizer"
mkdir -p "${STAGING_DIR}/usr/bin"
mkdir -p "${STAGING_DIR}/usr/share/applications"
mkdir -p "${STAGING_DIR}/usr/share/pixmaps"
mkdir -p "${STAGING_DIR}/usr/share/icons/hicolor/64x64/apps"
mkdir -p "${STAGING_DIR}/usr/share/mime/packages"
mkdir -p "${STAGING_DIR}/usr/share/metainfo"
mkdir -p "${STAGING_DIR}/usr/lib/udev/rules.d"

# Unpack binary distribution to staging
BIN_ZIP="$(ls -1 "${TOP_DIR}/target"/IrScrutinizer-*-bin.zip | head -n 1)"
unzip -q "${BIN_ZIP}" -d "${STAGING_DIR}/usr/share/irscrutinizer"

# Create symlinks in /usr/bin
for cmd in irscrutinizer irptransmogrifier harchardware AmxBeaconListenerPanel HexCalculator TimeFrequencyCalculator; do
    ln -sf "/usr/share/irscrutinizer/irscrutinizer.sh" "${STAGING_DIR}/usr/bin/${cmd}"
done

# Ensure wrapper script is executable
chmod 755 "${STAGING_DIR}/usr/share/irscrutinizer/irscrutinizer.sh"
chmod 755 "${STAGING_DIR}/usr/share/irscrutinizer/setup-irscrutinizer.sh"

# Install Desktop file
cat > "${STAGING_DIR}/usr/share/applications/irscrutinizer.desktop" << 'EOF'
[Desktop Entry]
Name=IrScrutinizer
GenericName=Infrared Signal Analyzer
Comment=Program for capturing, generating, analyzing, importing, and exporting infrared signals
Exec=/usr/bin/irscrutinizer %F
Icon=irscrutinizer
Terminal=false
Type=Application
Categories=AudioVideo;Development;Engineering;
MimeType=text/girr;application/xml;
StartupNotify=true
EOF
chmod 644 "${STAGING_DIR}/usr/share/applications/irscrutinizer.desktop"

# Install Icons
cp "${TOP_DIR}/src/main/resources/icons/Crystal-Clear/64x64/apps/babelfish.png" "${STAGING_DIR}/usr/share/pixmaps/irscrutinizer.png"
cp "${TOP_DIR}/src/main/resources/icons/Crystal-Clear/64x64/apps/babelfish.png" "${STAGING_DIR}/usr/share/icons/hicolor/64x64/apps/irscrutinizer.png"
chmod 644 "${STAGING_DIR}/usr/share/pixmaps/irscrutinizer.png"
chmod 644 "${STAGING_DIR}/usr/share/icons/hicolor/64x64/apps/irscrutinizer.png"

# Install MIME type
cp "${STAGING_DIR}/usr/share/irscrutinizer/girr.xml" "${STAGING_DIR}/usr/share/mime/packages/girr.xml"
chmod 644 "${STAGING_DIR}/usr/share/mime/packages/girr.xml"

# Install AppStream MetaInfo
cp "${TOP_DIR}/src/main/config/irscrutinizer.appdata.xml" "${STAGING_DIR}/usr/share/metainfo/irscrutinizer.appdata.xml"
chmod 644 "${STAGING_DIR}/usr/share/metainfo/irscrutinizer.appdata.xml"

# Install udev rules
cp "${STAGING_DIR}/usr/share/irscrutinizer/contributed/udev-rules/10-arduino.rules" "${STAGING_DIR}/usr/lib/udev/rules.d/10-arduino.rules"
cp "${STAGING_DIR}/usr/share/irscrutinizer/contributed/udev-rules/55-irtoy.rules" "${STAGING_DIR}/usr/lib/udev/rules.d/55-irtoy.rules"
chmod 644 "${STAGING_DIR}/usr/lib/udev/rules.d/"*.rules

# Ensure native arm64 / aarch64 libraries have executable permissions
chmod 755 "${STAGING_DIR}/usr/share/irscrutinizer"/Linux-*/*.so 2>/dev/null || true

# --- 2. Build Debian .deb Package ---
echo "--- Building Debian arm64 package ---"
DEB_BUILD_DIR="${TOP_DIR}/target/deb-build"
rm -rf "${DEB_BUILD_DIR}"
mkdir -p "${DEB_BUILD_DIR}/DEBIAN"
cp -a "${STAGING_DIR}/"* "${DEB_BUILD_DIR}/"

cat > "${DEB_BUILD_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION}-${RELEASE}
Section: sound
Priority: optional
Architecture: arm64
Maintainer: Bengt Martensson <barf@bengt-martensson.de>
Installed-Size: $(du -sk "${DEB_BUILD_DIR}" | cut -f1)
Depends: default-jre | java8-runtime | java11-runtime | java17-runtime | java21-runtime, libc6 (>= 2.17), libstdc++6 (>= 4.8)
Recommends: udev
Suggests: lirc
Description: Capture, generate, analyze, import, and export infrared signals
 IrScrutinizer is a powerful suite for working with infrared signals:
 capturing, decoding, analyzing, generating, and importing/exporting in
 numerous formats. Compatible with both 4k and 16k arm64 page kernels.
EOF

cat > "${DEB_BUILD_DIR}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
fi
exit 0
EOF
chmod 755 "${DEB_BUILD_DIR}/DEBIAN/postinst"

cat > "${DEB_BUILD_DIR}/DEBIAN/postrm" << 'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
fi
exit 0
EOF
chmod 755 "${DEB_BUILD_DIR}/DEBIAN/postrm"

DEB_FILE="${DIST_DIR}/${PKG_NAME}_${VERSION}-${RELEASE}_arm64.deb"
dpkg-deb --build --root-owner-group "${DEB_BUILD_DIR}" "${DEB_FILE}"
echo "Debian package created: ${DEB_FILE}"

# --- 3. Build Fedora RPM Package ---
echo "--- Building Fedora aarch64 RPM package ---"
RPM_TOPDIR="${TOP_DIR}/target/rpm-topdir"
rm -rf "${RPM_TOPDIR}"
mkdir -p "${RPM_TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

SPEC_FILE="${RPM_TOPDIR}/SPECS/${PKG_NAME}.spec"
cat > "${SPEC_FILE}" << EOF
Name:           ${PKG_NAME}
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Capture, generate, analyze, import, and export infrared signals
License:        GPL-3.0-or-later
URL:            https://github.com/bengtmartensson/IrScrutinizer
BuildArch:      aarch64
AutoReqProv:    no
Requires:       (java-headless >= 1:1.8.0 or java >= 1:1.8.0 or /usr/bin/java)
Requires:       glibc, libstdc++
Recommends:     systemd-udev, lirc

%description
IrScrutinizer is a powerful suite for working with infrared signals:
capturing, decoding, analyzing, generating, and importing/exporting in
numerous formats. Compatible with both 4k and 16k arm64 page kernels.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a ${STAGING_DIR}/* %{buildroot}/

%post
/usr/bin/update-desktop-database &> /dev/null || :
/usr/bin/update-mime-database /usr/share/mime &> /dev/null || :
/usr/bin/udevadm control --reload-rules &> /dev/null || :

%postun
/usr/bin/update-desktop-database &> /dev/null || :
/usr/bin/update-mime-database /usr/share/mime &> /dev/null || :
/usr/bin/udevadm control --reload-rules &> /dev/null || :

%files
/usr/bin/*
/usr/share/irscrutinizer
/usr/share/applications/irscrutinizer.desktop
/usr/share/pixmaps/irscrutinizer.png
/usr/share/icons/hicolor/64x64/apps/irscrutinizer.png
/usr/share/mime/packages/girr.xml
/usr/share/metainfo/irscrutinizer.appdata.xml
/usr/lib/udev/rules.d/10-arduino.rules
/usr/lib/udev/rules.d/55-irtoy.rules

EOF

rpmbuild --define "_topdir ${RPM_TOPDIR}" -bb "${SPEC_FILE}"
cp "${RPM_TOPDIR}"/RPMS/aarch64/*.rpm "${DIST_DIR}/"
echo "Fedora RPM package created in ${DIST_DIR}"

echo "=== All ARM64 packages successfully built in ${DIST_DIR} ==="
ls -lh "${DIST_DIR}"
