#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k

. /usr/share/beakerlib/beakerlib.sh || exit 1

JOSE_BIN="/usr/local/bin/jose"
TEST_DIR="${PWD}"
VECTOR_FIXTURE="${TEST_DIR}/data/ml-kem-768-fips203-vector.json"

b64url_size() {
    local value="$1"
    local remainder=$(( ${#value} % 4 ))

    case "${remainder}" in
        0) ;;
        2) value+="==" ;;
        3) value+="=" ;;
        *) return 1 ;;
    esac

    printf '%s' "${value}" | tr '_-' '/+' | base64 --decode | wc -c | tr -d '[:space:]'
}

mutate_b64url() {
    local value="$1"
    local index="$2"
    local original="${value:index:1}"
    local replacement="A"

    [[ "${original}" == "A" ]] && replacement="B"
    printf '%s%s%s' "${value:0:index}" "${replacement}" "${value:index+1}"
}

rlJournalStart
    rlPhaseStartSetup
        rlAssertExists "${JOSE_BIN}"
        rlAssertExists "${VECTOR_FIXTURE}"
        OPENSSL_VERSION="$(pkg-config --modversion openssl)"
        rlLogInfo "Using OpenSSL ${OPENSSL_VERSION}"
        IFS=. read -r OPENSSL_MAJOR OPENSSL_MINOR _ <<< "${OPENSSL_VERSION}"
        if (( OPENSSL_MAJOR < 3 || (OPENSSL_MAJOR == 3 && OPENSSL_MINOR < 5) )); then
            rlDie "OpenSSL 3.5 or newer is required for ML-KEM"
        fi

        rlRun "TmpDir=\$(mktemp -d)" 0 "Create a temporary test directory"
        rlRun "pushd '${TmpDir}'"
        rlRun "${JOSE_BIN} jwk gen -i '{\"alg\":\"ML-KEM-768\"}' > private.jwk" 0 "Generate an ML-KEM-768 key" || rlDie "The installed jose binary could not generate an ML-KEM-768 key"
    rlPhaseEnd

    rlPhaseStartTest "Key generation and public-key extraction"
        KTY="$(jq -r '.kty' private.jwk)"
        ALG="$(jq -r '.alg' private.jwk)"
        KEY_OPS="$(jq -r '.key_ops | join(",")' private.jwk)"
        PUBLIC_KEY="$(jq -r '.pub' private.jwk)"
        PRIVATE_KEY="$(jq -r '.priv' private.jwk)"

        rlAssertEquals "Generated key type" "AKP" "${KTY}"
        rlAssertEquals "Generated key algorithm" "ML-KEM-768" "${ALG}"
        rlAssertEquals "Generated key operation" "deriveKey" "${KEY_OPS}"
        rlAssertEquals "Public key size" "1184" "$(b64url_size "${PUBLIC_KEY}")"
        rlAssertEquals "Private seed size (d || z)" "64" "$(b64url_size "${PRIVATE_KEY}")"

        rlRun "${JOSE_BIN} jwk pub -i private.jwk > public.jwk" 0 "Extract public key"
        rlAssertEquals "Extracted public key matches" "${PUBLIC_KEY}" "$(jq -r '.pub' public.jwk)"
        rlRun "jq -e 'has(\"priv\") | not' public.jwk" 0 "Extracted key contains no private material"
    rlPhaseEnd

    rlPhaseStartTest "KEM encapsulation and decapsulation round-trip"
        rlRun "${JOSE_BIN} jwk encap -i public.jwk > encapsulation.json" 0 "Encapsulate to the public key"
        CIPHERTEXT="$(jq -r '.ct' encapsulation.json)"
        SHARED_SECRET="$(jq -r '.ss.k' encapsulation.json)"
        rlAssertEquals "Ciphertext size" "1088" "$(b64url_size "${CIPHERTEXT}")"
        rlAssertEquals "Shared secret size" "32" "$(b64url_size "${SHARED_SECRET}")"
        rlAssertEquals "Encapsulation secret type" "oct" "$(jq -r '.ss.kty' encapsulation.json)"

        rlRun "${JOSE_BIN} jwk decap -i private.jwk -c '${CIPHERTEXT}' > decapsulation.jwk" 0 "Decapsulate ciphertext"
        rlAssertEquals "Decapsulation secret type" "oct" "$(jq -r '.kty' decapsulation.jwk)"
        rlAssertEquals "Round-trip shared secrets match" "${SHARED_SECRET}" "$(jq -r '.k' decapsulation.jwk)"
    rlPhaseEnd

    rlPhaseStartTest "FIPS 203 static vector fixture"
        # TODO: Replace this FIPS 203 fixture with official JOSE PQC KEM vectors once published.
        # Update the fixture mapping if the JOSE vector format differs.
        rlRun "jq '.private_key' '${VECTOR_FIXTURE}' > vector-private.jwk" 0 "Load the static ML-KEM-768 key fixture"
        VECTOR_SOURCE="$(jq -r '.source' "${VECTOR_FIXTURE}")"
        VECTOR_PUBLIC_KEY="$(jq -r '.private_key.pub' "${VECTOR_FIXTURE}")"
        VECTOR_PRIVATE_KEY="$(jq -r '.private_key.priv' "${VECTOR_FIXTURE}")"
        VECTOR_CIPHERTEXT="$(jq -r '.ct' "${VECTOR_FIXTURE}")"
        VECTOR_SHARED_SECRET="$(jq -r '.ss' "${VECTOR_FIXTURE}")"
        rlLogInfo "Using static vector fixture: ${VECTOR_SOURCE}"
        rlAssertEquals "Fixture public key size" "1184" "$(b64url_size "${VECTOR_PUBLIC_KEY}")"
        rlAssertEquals "Fixture private seed size" "64" "$(b64url_size "${VECTOR_PRIVATE_KEY}")"
        rlAssertEquals "Fixture ciphertext size" "1088" "$(b64url_size "${VECTOR_CIPHERTEXT}")"
        rlAssertEquals "Fixture shared-secret size" "32" "$(b64url_size "${VECTOR_SHARED_SECRET}")"

        rlRun "${JOSE_BIN} jwk pub -i vector-private.jwk > vector-public.jwk" 0 "Extract the fixture public key"
        rlAssertEquals "Fixture public key matches" "${VECTOR_PUBLIC_KEY}" "$(jq -r '.pub' vector-public.jwk)"
        rlRun "${JOSE_BIN} jwk decap -i vector-private.jwk -c '${VECTOR_CIPHERTEXT}' > vector-secret.jwk" 0 "Decapsulate the fixture ciphertext"
        rlAssertEquals "Fixture decapsulation secret type" "oct" "$(jq -r '.kty' vector-secret.jwk)"
        rlAssertEquals "Fixture shared secret matches" "${VECTOR_SHARED_SECRET}" "$(jq -r '.k' vector-secret.jwk)"
    rlPhaseEnd

    rlPhaseStartTest "Implicit rejection"
        # Change valid base64url characters so each corrupted ciphertext keeps its original length.
        CORRUPT_SECRETS=()
        CIPHERTEXT_LENGTH="${#CIPHERTEXT}"
        for INDEX in 0 $(( CIPHERTEXT_LENGTH / 2 )) $(( CIPHERTEXT_LENGTH / 2 + 13 )); do
            CORRUPTED_CIPHERTEXT="$(mutate_b64url "${CIPHERTEXT}" "${INDEX}")"
            OUTPUT_FILE="corrupt-${INDEX}.json"
            rlRun "${JOSE_BIN} jwk decap -i private.jwk -c '${CORRUPTED_CIPHERTEXT}' > '${OUTPUT_FILE}'" 0 "Decapsulate corrupted ciphertext at offset ${INDEX}"
            CORRUPTED_SECRET="$(jq -r '.k' "${OUTPUT_FILE}")"
            rlAssertNotEquals "Implicit rejection changes the secret at offset ${INDEX}" "${SHARED_SECRET}" "${CORRUPTED_SECRET}"
            for PREVIOUS_SECRET in "${CORRUPT_SECRETS[@]}"; do
                rlAssertNotEquals "Implicit rejection output varies across corruptions" "${PREVIOUS_SECRET}" "${CORRUPTED_SECRET}"
            done
            CORRUPT_SECRETS+=("${CORRUPTED_SECRET}")
        done

        REPEATED_CIPHERTEXT="$(mutate_b64url "${CIPHERTEXT}" 0)"
        rlRun "${JOSE_BIN} jwk decap -i private.jwk -c '${REPEATED_CIPHERTEXT}' > repeated-corrupt.json" 0 "Decapsulate the same corrupted ciphertext again"
        rlAssertEquals "Implicit rejection is deterministic for identical ciphertext" \
            "$(jq -r '.k' corrupt-0.json)" "$(jq -r '.k' repeated-corrupt.json)"

        rlRun "${JOSE_BIN} jwk gen -i '{\"alg\":\"ML-KEM-768\"}' > other-private.jwk" 0 "Generate a second key"
        rlRun "${JOSE_BIN} jwk decap -i other-private.jwk -c '${CIPHERTEXT}' > wrong-key.jwk" 0 "Decapsulate with a different private key"
        rlAssertNotEquals "Wrong-key decapsulation returns a different secret" "${SHARED_SECRET}" "$(jq -r '.k' wrong-key.jwk)"
    rlPhaseEnd

    rlPhaseStartTest "Malformed input rejection"
        rlRun "jq '.pub = \"not*base64url\"' public.jwk > malformed-public.jwk" 0 "Create a key with invalid encoding"
        rlRun "${JOSE_BIN} jwk encap -i malformed-public.jwk" 1 "Reject malformed public-key encoding"

        rlRun "jq '.priv |= .[:-2]' private.jwk > short-private.jwk" 0 "Create a private seed with the wrong length"
        rlRun "${JOSE_BIN} jwk decap -i short-private.jwk -c '${CIPHERTEXT}'" 1 "Reject a private seed with the wrong length"

        rlRun "jq '.alg = \"ML-KEM-512\"' private.jwk > wrong-suite-private.jwk" 0 "Create a key for another parameter set"
        rlRun "${JOSE_BIN} jwk decap -i wrong-suite-private.jwk -c '${CIPHERTEXT}'" 1 "Reject a cross-suite ciphertext"

        SHORT_CIPHERTEXT="${CIPHERTEXT%?}"
        rlRun "${JOSE_BIN} jwk decap -i private.jwk -c '${SHORT_CIPHERTEXT}'" 1 "Reject a ciphertext with the wrong length"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "rm -rf '${TmpDir}'" 0 "Remove temporary key material"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
