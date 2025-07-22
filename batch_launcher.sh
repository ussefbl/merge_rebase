#!/bin/bash

#**************************************************************************
#  SCRIPT              : batch-launcher.sh
#  DESCRIPTION         : Lance des batchs Interface et Progiciel
# --------------------------------------------------------------------------
#  PARAMETRES          :
#    1. $1             : BATCH_CODE Code du batch a executer (exemple: INTERFACE-AISUITE).
# --------------------------------------------------------------------------
#  FONCTIONNALITE      :
#    - Verifier l'environnement d'execution et s'assurer que les variables et dossiers necessaires existent
#    - Determiner le type de batch (PROGICIEL ou INTERFACE) en fonction du BATCH_CODE
#    - Executer les batchs via CMD JAVA
#    - Archiver les fichiers `.par` et `.v9r` apres l'execution
#    - Fichier de log specifique pour chaque execution
# --------------------------------------------------------------------------
#  REGLE DE GESTION
#    - BATCH INTERFACE: BATCH OK si code retour=0
#    - BATCH PROGICIEL: BATCH OK si code retour=0 ou 1 ou 2
# --------------------------------------------------------------------------
#**************************************************************************

# --------------------------------------------------------------------------------------------
# Sourcing variables depuis TFS

BATCH_CODE=$1
# Chemin du script et on definit le chemin du fichier properties
BATCH_DIR_PATH="$(dirname "$(realpath $0)")"
PROPERTIES_FILE="${BATCH_DIR_PATH}/../param/batch-launcher-properties.sh"

# Si le fichier de proprietes n'existe pas, on arrete le script
if [[ ! -f "${PROPERTIES_FILE}" ]]; then
    echo "[ERROR] Properties file not found [${PROPERTIES_FILE}]"
    exit 1
fi

# Import (source) des variables definies dans le fichier de proprietes
source "${PROPERTIES_FILE}"

DIRNAME="$(cd "$(dirname "$BASH_SOURCE")" ; pwd -P )"
UENV="$(echo "$DIRNAME" | awk -F"/" '{ print $5 }')"
PACKAGE="$(echo "$DIRNAME" | awk -F"/" '{ print $3 }')"

APP_HOME="/app/${PACKAGE}/clevacol/${UENV}"

# Fichier de log specifique a chaque execution
DATENOW=$(date +"%Y%m%d")

if [ -z "${BATCH_CODE}" ]; then
    BATCH_CODE="ERR_BATCH_CODE"
fi

LOG_FILE="${DEFAULT_LOG_PATH}/batch-launcher_${BATCH_CODE}_${DATENOW}.log"

# Separator for java classpath (Linux: ":", Windows: ";")
LINUX_PATH_SEPARATOR=":"
PATH_SEPARATOR=${PATH_SEPARATOR:-${LINUX_PATH_SEPARATOR}}

# Definition des chemins vers les librairies et le binaire java
JAVA_LIB_DIR_PATH="$(realpath "${APP_HOME}/clevacol-batchs-dist")"
JAVA_PATH="${JAVA_PATH:-${JAVA_PATH_VAR}}"
JAVA_CP_PROGICIEL="${JAVA_LIB_DIR_PATH}/lib/*${PATH_SEPARATOR}${JAVA_LIB_DIR_PATH}/conf${PATH_SEPARATOR}."
JAVA_CP_INTERFACE="${JAVA_LIB_DIR_PATH}/bin/clevacol-batchs-interfaces.jar${PATH_SEPARATOR}${JAVA_LIB_DIR_PATH}/lib/*${PATH_SEPARATOR}${JAVA_LIB_DIR_PATH}/conf${PATH_SEPARATOR}."

JAVA_CLASS_PROGICIEL="com.itnsa.fwk.batch.client.V9BatchClient"
JAVA_CLASS_INTERFACE="org.springframework.batch.core.launch.support.CommandLineJobRunner"

# Tableau des variables a verifier avant execution
properties_required_variables=(
    JAVA_XMS_BAT_SPE JAVA_XMX_BAT_SPE
    JAVA_XMS_BAT_PRO JAVA_XMX_BAT_PRO \
    JAVA_XMX_BATCH_SPECIFIQUE \
    JAVA_PATH_VAR DEFAULT_LOG_PATH ARCH_DIR_PATH PAR_DIR_PATH \
    USER_CLEVA PWD_CLEVA SOCIETE
)

# --------------------------------------------------------------------------------------------
function getScriptName() {
  # nom du script sans extension
  typeset script_name=$(basename $0)
  # remove '-*' :
  script_name=$(expr "$script_name" : '-*\(.*\)')
  # remove filename extension :
  echo ${script_name%.*}
}

# --------------------------------------------------------------------------------------------
function traceLog() {
  # format  [06/10/2023 02:42:15]
  MESSAGE=`date +"[%d/%m/%Y %H:%M:%S]"`" - ${1}"
  echo "${MESSAGE}" | tee -a "${LOG_FILE}"
}

# --------------------------------------------------------------------------------------------
function checkJavaVersion() {
    # Verification de Java version necessaire a l'execution
    JVM_VERSION=$("${JAVA_PATH}" -version 2>&1 | tr '\n' ' ')
    traceLog "[INFO] JAVA version detected [${JVM_VERSION}]"

    if [[ "${JVM_VERSION}" != *"1.8"* && "${JVM_VERSION}" != *"1.9"* ]]; then
        traceLog "[ERROR] Java 1.8.x is required"
        traceLog "[INFO] END OF SCRIPT [${SCRIPTNAME}]"
        exit 1
    fi
}

# --------------------------------------------------------------------------------------------
function checkEnvironment() {
    # Verification de la presence des dossiers requis et des variables indispensables
    traceLog "[INFO] Checking environment"

    REQUIRED_DIRS=("${JAVA_LIB_DIR_PATH}/lib" "${JAVA_LIB_DIR_PATH}/conf" "${JAVA_LIB_DIR_PATH}/bin")
    for dir in "${REQUIRED_DIRS[@]}"; do
        if [ ! -d "${dir}" ]; then
            traceLog "[ERROR] Required directory not found [${dir}]"
            traceLog "[INFO] END OF SCRIPT"
            exit 1
        fi
    done

    for var in "${properties_required_variables[@]}"; do
      if [[ -z "${!var}" ]]; then
          traceLog "[ERROR] Required variable is not set [${var}] Check the properties file [${PROPERTIES_FILE}]"
          traceLog "[INFO] END OF SCRIPT"
          exit 1
      fi
    done
    traceLog "[INFO] Checking environnement [OK]"
}

# --------------------------------------------------------------------------------------------
function getBatchType() {
    # Determine si on est sur un batch INTERFACE ou PROGICIEL
    PARFILE_PREFIX=""
    JOB_NAME=""
    TYPE_BATCH=""

    if [[ "${BATCH_CODE}" =~ INTERFACE.* ]]; then
        # INTERFACE
        PARFILE_PREFIX="GenericBatch_${BATCH_CODE}_*.par"
        JOB_NAME=$(echo "${BATCH_CODE}" | cut -d'-' -f2 | tr '[:upper:]' '[:lower:]')
        TYPE_BATCH="INTERFACE"
    else
        # PROGICIEL
        PARFILE_PREFIX="*_${BATCH_CODE}_*.par"
        TYPE_BATCH="PROGICIEL"
    fi
    traceLog "[INFO] BATCH [${TYPE_BATCH}] PARFILE_PREFIX [${PARFILE_PREFIX}] JOB_NAME [${JOB_NAME}]"
}

# --------------------------------------------------------------------------------------------
function displayParFileContent() {
    # Affichage du contenu des fichier .par dans les log
    parfile=$1
    parfile_name="$(basename "${parfile}")"
    count_line=0
    if [ -f "${parfile}" ]; then
        traceLog "[INFO] Content .par file [${parfile_name}]:"

        # Read each line from the .par file without splitting by spaces or tabs
        # IFS (Internal Field Separator) Prevents Bash from splitting lines on spaces or other default separators
        while IFS='' read -r line; do
            count_line=$((count_line + 1))
            line_with_tabs=$(echo "${line}" | sed $'s/\t/ -> /g')
            traceLog "[INFO] PARAM[${count_line}] [${line_with_tabs}]"
        done < "${parfile}"
    fi
}

# --------------------------------------------------------------------------------------------
function archiveParFile() {
    # Archivage des fichier .par et .v9r
    parfile=$1
    v9rfile="${parfile%.par}.v9r"
    archive_path="${ARCH_DIR_PATH}/${DATENOW}"

    if ! mkdir -p "${archive_path}" 2>> "${LOG_FILE}"; then
        traceLog "[ERROR] FAILED to create directory ${archive_path}"
    fi

    mv -f "${parfile}" "${archive_path}" 2>> "${LOG_FILE}"
    if [ -f "${archive_path}/$(basename "${parfile}")" ]; then
        traceLog "[INFO] Archived .par file [${parfile}] to [${archive_path}]"
    else
        traceLog "[ERROR] FAILED to archive .par file [${parfile}] to [${archive_path}]"
    fi

    if [ -f "${v9rfile}" ]; then
        if ! mv -f "${v9rfile}" "${archive_path}" 2>> "${LOG_FILE}"; then
            traceLog "[ERROR] FAILED to archive .v9r file [${v9rfile}] to [${archive_path}]"
        else
            traceLog "[INFO] Archived .v9r file [${v9rfile}] to [${archive_path}]"
        fi
    fi
}

# --------------------------------------------------------------------------------------------
function progicielBatchLauncher() {
    # Execute batch progiciel
    parfile=$1
    parfile_name="$(basename "${parfile}")"
    v9rfile="${parfile%.par}.v9r"

    traceLog "[INFO] EXECUTION BATCH PROGICIEL  JOB_NAME [${JOB_NAME}] BATCH_CODE [${BATCH_CODE}] PAR [${parfile_name}]"
    displayParFileContent "${parfile}"

    JAVA_OPTS_PROGICIEL="-Xms${JAVA_XMS_BAT_PRO} -Xmx${JAVA_XMX_BAT_PRO} -Duser.language=fr -Duser.country=FR"

    CMD_LINE="${JAVA_PATH} -cp ${JAVA_CP_PROGICIEL} ${JAVA_OPTS_PROGICIEL} ${JAVA_CLASS_PROGICIEL} ${USER_CLEVA} ${PWD_CLEVA} ${SOCIETE} ${parfile_name}"
    # Cacher le MDP dans la commande
    CMD_LINE_LOG=$(echo "${CMD_LINE}" | sed "s/${PWD_CLEVA}/******/g")
    traceLog "[INFO] EXECUTION COMMAND LINE [${CMD_LINE_LOG}]"

    # Execute java Command (progiciel)
    ${CMD_LINE}
    rc_batch=$?

    # Recuperation du code retour et eventuellement celui dans .v9r
    if [ -f "${v9rfile}" ]; then
        rc_v9r=$(cat "${v9rfile}" | tr -d '[:space:]')
        if [[ "${rc_batch}" -ne "${rc_v9r}" ]]; then
            rc_batch="${rc_v9r}"
        fi
    fi
    return "${rc_batch}"
}

# --------------------------------------------------------------------------------------------
function interfaceBatchLauncher() {
    # Execute batch interface
    parfile=$1
    JOB_CONTEXT="jobs/${JOB_NAME}.xml"
    parfile_name="$(basename "${parfile}")"

    traceLog "[INFO] EXECUTION BATCH INTERFACE  JOB_NAME [${JOB_NAME}] BATCH_CODE [${BATCH_CODE}] PAR [${parfile_name}]"
    displayParFileContent "${parfile}"

    # Liste des batchs necessitant XMX=10Go (liste separee par espace)
    if [[ "${LIST_BATCH_CODE[@]}" =~ "${BATCH_CODE}" ]]; then
        traceLog "[INFO] BATCH INTERFACE high memory needed 10Go"
        JAVA_XMX_BAT_SPE="${JAVA_XMX_BATCH_SPECIFIQUE}"
    fi

    # Configuration agent Dynatrace
    DYN_AGENT_OPTS=""
    if [[ -f  "${DYN_AGENT_LIB}" ]]  ; then
        DYN_AGENT_OPTS="${DYN_AGENT_OPTS} -agentpath:${DYN_AGENT_LIB}=name=${DYN_AGENT_NAME},server=${DYN_COLLECTEUR}"
    fi

    CMD_LINE="${JAVA_PATH} -Xmx${JAVA_XMX_BAT_SPE} -Xms${JAVA_XMS_BAT_SPE} ${DYN_AGENT_OPTS} -Denv.jobname=${JOB_NAME} -cp ${JAVA_CP_INTERFACE} ${JAVA_CLASS_INTERFACE} ${JOB_CONTEXT} ${JOB_NAME} par=${parfile}"
    traceLog "[INFO] EXECUTION COMMAND LINE [${CMD_LINE}]"
    # Execute java Command (interface)
    ${CMD_LINE}
    rc_batch=$?
    return "${rc_batch}"
}

# --------------------------------------------------------------------------------------------
function main() {
    SCRIPTNAME=`getScriptName`
    traceLog "[INFO] START SCRIPT [${SCRIPTNAME}]"

    # Verification de la presence arguement (BATCH_CODE)
    if [[ "$#" -lt 1 ]]; then
        traceLog "[INFO] Argument needed [BATCH_CODE]"
        traceLog "[INFO] END OF SCRIPT [${SCRIPTNAME}]"
        exit 1
    fi
    # Check environment variable and Java version
    checkJavaVersion
    checkEnvironment

    # Get batch type
    getBatchType

    # Find all .par files to process
    mapfile par_list < <(find "${PAR_DIR_PATH}" -maxdepth 1 -type f -name "${PARFILE_PREFIX}")

    if [ "${#par_list[@]}" -eq 0 ]; then
        traceLog "[INFO] No .par files found for batch [${BATCH_CODE}]"
        traceLog "[INFO] END OF SCRIPT [${SCRIPTNAME}]"
        exit 0
    fi
    # Lance batch selon type interface ou progiciel
    for parfile in ${par_list[@]} ; do
        # Interface
        if [[ "${TYPE_BATCH}" == "INTERFACE" ]]; then
            interfaceBatchLauncher "${parfile}"

            if [[ "${rc_batch}" -eq 0 ]]; then
                archiveParFile "${parfile}"
                traceLog "[INFO] CMD INTERFACE BATCH succeeded with Return code [${rc_batch}]"
            else
                traceLog "[ERROR] EXECUTION FAILED OF CMD BATCH INTERFACE with Return code [${rc_batch}]"
            fi
        else
            # Progiciel
            progicielBatchLauncher "${parfile}"

            if [[ "${rc_batch}" -eq 0 || "${rc_batch}" -eq 1 || "${rc_batch}" -eq 2 ]]; then
                archiveParFile "${parfile}"
                traceLog "[INFO] CMD PROGICIEL BATCH succeeded with Return code [${rc_batch}]"
            else
                traceLog "[ERROR] EXECUTION FAILED OF CMD BATCH PROGICIEL with Return code [${rc_batch}]"
            fi
        fi
    done
    traceLog "[INFO] Log file [${LOG_FILE}]"
    traceLog "[INFO] END OF SCRIPT [${SCRIPTNAME}]"
    return "${rc_batch}"
}

# --------------------------------------------------------------------------------------------

main "$@"

exit "${rc_batch}"
