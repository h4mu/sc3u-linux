#!/bin/sh -e
PATCH_FNAME='sc3u-2.0a-x86.run'
PATCH_FIX='sc3u-2.0a-x86.run.patch'
LOKI_COMPAT='loki_compat_libs-1.5.tar.bz2'
SC3U_PATH=${SC3U_PATH:-/usr/local/games/SC3U}
CDROM_PATH=${CDROM_PATH:-/mnt}
BINDIR=${BINDIR:-/usr/local/bin}
BASE_BIN_PATH="$CDROM_PATH/bin/x86/glibc-2.1"
PATCH_URL='https://updates.lokigames.com/sc3u'
LOKI_URL='https://www.improbability.net/loki'

SCRIPT_DIR=$(dirname "$0")
cd "$SCRIPT_DIR"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=
else
  SUDO=sudo
fi

# Check for required programs
RPROGRAMS="curl cat patch tar install linux32"
for RPROGRAM in ${RPROGRAMS}; do
  if ! command -v "${RPROGRAM}" >/dev/null 2>&1; then
    echo "ERROR: Required binary ${RPROGRAM} not found. Install it to proceed"
    exit 1
  fi
done

if [ ! -d "${SC3U_PATH}" ]; then
  echo "ERROR: ${SC3U_PATH} not found. Install the game first."
  exit 1
fi

# The original Loki installer does not work reliably on 64-bit systems, and
# sometimes it leaves the installation with data files only. Complete the
# missing binary part from the mounted CD/ISO.
if [ ! -d "${SC3U_PATH}/lib" ] || [ ! -x "${SC3U_PATH}/sc3u" ]; then
  if [ ! -x "${BASE_BIN_PATH}/sc3u" ] || [ ! -d "${BASE_BIN_PATH}/lib" ]; then
    echo "ERROR: Base game binaries not found under ${BASE_BIN_PATH}."
    echo "Mount the SimCity 3000 Unlimited CD/ISO on ${CDROM_PATH}, or set CDROM_PATH."
    exit 1
  fi
  echo "Installing missing base game binaries from ${BASE_BIN_PATH}"
  ${SUDO} install -d "${SC3U_PATH}/lib"
  ${SUDO} cp -a "${BASE_BIN_PATH}/lib/." "${SC3U_PATH}/lib/"
  ${SUDO} chmod -R u+w "${SC3U_PATH}/lib"
  if [ ! -x "${SC3U_PATH}/sc3u" ]; then
    ${SUDO} install -m755 "${BASE_BIN_PATH}/sc3u" "${SC3U_PATH}/sc3u"
  fi
  if [ ! -x "${SC3U_PATH}/sc3bat" ] && [ -x "${BASE_BIN_PATH}/sc3bat" ]; then
    ${SUDO} install -m755 "${BASE_BIN_PATH}/sc3bat" "${SC3U_PATH}/sc3bat"
  fi
fi

# Download the official 2.0a patch
if [ ! -f "${PATCH_FNAME}" ]; then
  echo "Downloading ${PATCH_FNAME}"
  curl -fL "${PATCH_URL}/${PATCH_FNAME}" -o "${PATCH_FNAME}"
fi

# Fix compatibility problems with modern POSIX shells
if ! grep -aq '^skip=180' "${PATCH_FNAME}" || \
   ! grep -aqF 'script="linux32 ./update.sh"' "${PATCH_FNAME}" || \
   ! grep -aqF 'tail -n +$skip' "${PATCH_FNAME}"; then
  echo "Applying linux32/POSIX compatibility fixes to the patch"
  patch -p0 < "${PATCH_FIX}"
fi

# Run the patch, unless it was already applied
if [ -x "${SC3U_PATH}/sc3u.dynamic" ] && [ -f "${SC3U_PATH}/README-2.0a" ]; then
  echo "SimCity 3000 2.0a update already applied"
else
  echo "Applying SimCity 3000 Unlimited 2.0a update"
  PATCH_DIR="${TMPDIR:-/tmp}/sc3u-patch.$$"
  ${SUDO} rm -rf "${PATCH_DIR}"
  if ! ${SUDO} sh "${PATCH_FNAME}" --keep --target "${PATCH_DIR}" "${SC3U_PATH}"; then
    echo "ERROR: The 2.0a update failed. Extracted patch kept at ${PATCH_DIR}"
    exit 1
  fi
  ${SUDO} rm -rf "${PATCH_DIR}"
fi

# Download and install the Loki compatibility libraries
echo "Installing Loki compatibility libraries"
if [ ! -f "${LOKI_COMPAT}" ]; then
  curl -fL "${LOKI_URL}/${LOKI_COMPAT}" -o "${LOKI_COMPAT}"
fi
${SUDO} tar -xjf "${LOKI_COMPAT}" -C "${SC3U_PATH}"

for LIB in ld-linux.so.2 libSDL-1.1.so.0 libsmpeg-0.4.so.0 libopenal-0.0.so; do
  if [ ! -e "${SC3U_PATH}/Loki_Compat/${LIB}" ]; then
    echo "ERROR: ${LIB} not found in Loki_Compat after extraction"
    exit 1
  fi
done

# Install a launcher, keeping the patched static binary as sc3u.old
if ! grep -aq 'Loki_Compat/ld-linux.so.2' "${SC3U_PATH}/sc3u" 2>/dev/null; then
  ${SUDO} cp -p "${SC3U_PATH}/sc3u" "${SC3U_PATH}/sc3u.old"
fi

LAUNCHER="${TMPDIR:-/tmp}/sc3u-launcher.$$"
cat > "${LAUNCHER}" <<EOF
#!/bin/sh
SCPATH='${SC3U_PATH}'
cd "\$SCPATH" || exit 1
export LD_LIBRARY_PATH="\$SCPATH/lib:\$SCPATH/Loki_Compat"
export LD_ASSUME_KERNEL=2.2.5
export LANG=en_US.UTF-8
export SDL_AUDIODRIVER=dsp
export AUDIODEV=/dev/dsp
export SDL_VIDEO_YUV_HWACCEL=0
exec "\$SCPATH/Loki_Compat/ld-linux.so.2" "\$SCPATH/sc3u.dynamic" "\$@"
EOF
${SUDO} install -m755 "${LAUNCHER}" "${SC3U_PATH}/sc3u"
rm -f "${LAUNCHER}"
${SUDO} install -d "${BINDIR}"
${SUDO} ln -sf "${SC3U_PATH}/sc3u" "${BINDIR}/sc3u"

# Emulate OSS audio through PulseAudio/PipeWire when possible
install_sound() {
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "Install osspd and osspd-pulseaudio manually to enable sound."
    return
  fi
  if dpkg -s osspd >/dev/null 2>&1 && dpkg -s osspd-pulseaudio >/dev/null 2>&1; then
    echo "osspd is already installed"
  else
    echo "Installing osspd and osspd-pulseaudio"
    if ! ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get update; then
      echo "WARNING: apt-get update failed; sound setup skipped"
      return
    fi
    if ! ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y osspd osspd-pulseaudio; then
      echo "WARNING: osspd installation failed; sound setup skipped"
      return
    fi
  fi
  ${SUDO} modprobe cuse >/dev/null 2>&1 || true
  if command -v systemctl >/dev/null 2>&1; then
    if ! ${SUDO} systemctl enable --now osspd; then
      echo "WARNING: Could not start osspd; check: systemctl status osspd"
    fi
  elif command -v service >/dev/null 2>&1; then
    ${SUDO} service osspd start || true
  fi
  sleep 1
  if [ -e /dev/dsp ]; then
    echo "OSS sound device available: $(ls -l /dev/dsp)"
  else
    echo "WARNING: /dev/dsp not present; sound may not work"
  fi
}
install_sound

cat <<EOF

SimCity 3000 Unlimited setup complete.

Run windowed first:
    sc3u -w

If that works, run fullscreen:
    sc3u

Sound troubleshooting:
    systemctl status osspd
    ls -l /dev/dsp
EOF
