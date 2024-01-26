//
// Subworkflow with functionality specific to the nf-core/fetchngs pipeline
//

/*
========================================================================================
    IMPORT MODULES/SUBWORKFLOWS
========================================================================================
*/

include { UTILS_NFVALIDATION_PLUGIN } from '../../nf-core/utils_nfvalidation_plugin'
include { fromSamplesheet           } from 'plugin/nf-validation'
include { paramsSummaryMap          } from 'plugin/nf-validation'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { dashedLine                } from '../../nf-core/utils_nfcore_pipeline'
include { nfCoreLogo                } from '../../nf-core/utils_nfcore_pipeline'
include { imNotification            } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { workflowCitation          } from '../../nf-core/utils_nfcore_pipeline'

/*
========================================================================================
    SUBWORKFLOW TO INITIALISE PIPELINE
========================================================================================
*/

workflow PIPELINE_INITIALISATION {

    take:
    version             // boolean: Display version and exit
    help                // boolean: Display help text
    validate_params     // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs     // boolean: Do not use coloured log outputs
    outdir              //  string: The output directory where the results will be saved
    input               //  string: File containing SRA/ENA/GEO/DDBJ identifiers one per line to download their associated metadata and FastQ files
    input_type          //  string: Specifies the type of identifier provided via `--input` - available options are 'sra' and 'synapse'
    ena_metadata_fields //  string: Comma-separated list of ENA metadata fields to fetch before downloading data

    main:

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    def pre_help_text = nfCoreLogo(monochrome_logs)
    def post_help_text = '\n' + workflowCitation() + '\n' + dashedLine(monochrome_logs)
    def String workflow_command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input ids.csv --outdir <OUTDIR>"
    UTILS_NFVALIDATION_PLUGIN (
        help,
        workflow_command,
        pre_help_text,
        post_help_text,
        validate_params,
        "nextflow_schema.json"
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE ()

    //
    // Auto-detect input id type
    //
    ch_input = file(input)
    def inferred_input_type = ''
    if (isSraId(ch_input)) {
        inferred_input_type = 'sra'
        sraCheckENAMetadataFields(ena_metadata_fields)
    } else if (isSynapseId(ch_input)) {
        inferred_input_type = 'synapse'
    } else {
        error('Ids provided via --input not recognised please make sure they are either SRA / ENA / GEO / DDBJ or Synapse ids!')
    }

    if (input_type != inferred_input_type) {
        error("Ids auto-detected as ${inferred_input_type}. Please provide '--input_type ${inferred_input_type}' as a parameter to the pipeline!")
    }

    // Read in ids from --input file
    Channel
        .from(ch_input)
        .splitCsv(header:false, sep:'', strip:true)
        .map { it[0] }
        .unique()
        .set { ch_ids }

    emit:
    ids = ch_ids
}

/*
========================================================================================
    SUBWORKFLOW FOR PIPELINE COMPLETION
========================================================================================
*/

workflow PIPELINE_COMPLETION {

    take:
    input_type      //  string: 'sra' or 'synapse'
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications

    main:

    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(summary_params, email, email_on_fail, plaintext_email, outdir, monochrome_logs)
        }

        completionSummary(monochrome_logs)

        if (hook_url) {
            imNotification(summary_params, hook_url)
        }

        if (input_type == 'sra') {
            sraCurateSamplesheetWarn()
        } else if (input_type == 'synapse') {
            synapseCurateSamplesheetWarn()
        }
    }
}

/*
========================================================================================
    FUNCTIONS
========================================================================================
*/

//
// Check if input ids are from the SRA
//
def isSraId(input) {
    def is_sra = false
    def total_ids = 0
    def no_match_ids = []
    def pattern = /^(((SR|ER|DR)[APRSX])|(SAM(N|EA|D))|(PRJ(NA|EB|DB))|(GS[EM]))(\d+)$/
    input.eachLine { line ->
        total_ids += 1
        if (!(line =~ pattern)) {
            no_match_ids << line
        }
    }

    def num_match = total_ids - no_match_ids.size()
    if (num_match > 0) {
        if (num_match == total_ids) {
            is_sra = true
        } else {
            error("Mixture of ids provided via --input: ${no_match_ids.join(', ')}\nPlease provide either SRA / ENA / GEO / DDBJ or Synapse ids!")
        }
    }
    return is_sra
}

//
// Check if input ids are from the Synapse platform
//
def isSynapseId(input) {
    def is_synapse = false
    def total_ids = 0
    def no_match_ids = []
    def pattern = /^syn\d{8}$/
    input.eachLine { line ->
        total_ids += 1
        if (!(line =~ pattern)) {
            no_match_ids << line
        }
    }

    def num_match = total_ids - no_match_ids.size()
    if (num_match > 0) {
        if (num_match == total_ids) {
            is_synapse = true
        } else {
            error("Mixture of ids provided via --input: ${no_match_ids.join(', ')}\nPlease provide either SRA / ENA / GEO / DDBJ or Synapse ids!")
        }
    }
    return is_synapse
}

//
// Check and validate parameters
//
def sraCheckENAMetadataFields(ena_metadata_fields) {
    // Check minimal ENA fields are provided to download FastQ files
    def valid_ena_metadata_fields = ['run_accession', 'experiment_accession', 'library_layout', 'fastq_ftp', 'fastq_md5']
    def actual_ena_metadata_fields = ena_metadata_fields ? ena_metadata_fields.split(',').collect{ it.trim().toLowerCase() } : valid_ena_metadata_fields
    if (!actual_ena_metadata_fields.containsAll(valid_ena_metadata_fields)) {
        error("Invalid option: '${ena_metadata_fields}'. Minimally required fields for '--ena_metadata_fields': '${valid_ena_metadata_fields.join(',')}'")
    }
}

//
// Print a warning after pipeline has completed
//
def sraCurateSamplesheetWarn() {
    log.warn "=============================================================================\n" +
        "  Please double-check the samplesheet that has been auto-created by the pipeline.\n\n" +
        "  Public databases don't reliably hold information such as strandedness\n" +
        "  information, controls etc\n\n" +
        "  All of the sample metadata obtained from the ENA has been appended\n" +
        "  as additional columns to help you manually curate the samplesheet before\n" +
        "  running nf-core/other pipelines.\n" +
        "==================================================================================="
}

//
// Convert metadata obtained from the 'synapse show' command to a Groovy map
//
def synapseShowToMap(synapse_file) {
    def meta = [:]
    def category = ''
    synapse_file.eachLine { line ->
        def entries = [null, null]
        if (!line.startsWith(' ') && !line.trim().isEmpty()) {
            category = line.tokenize(':')[0]
        } else {
            entries = line.trim().tokenize('=')
        }
        meta["${category}|${entries[0]}"] = entries[1]
    }
    meta.id = meta['properties|id']
    meta.name = meta['properties|name']
    meta.md5 = meta['File|md5']
    return meta.findAll{ it.value != null }
}

//
// Print a warning after pipeline has completed
//
def synapseCurateSamplesheetWarn() {
    log.warn "=============================================================================\n" +
        "  Please double-check the samplesheet that has been auto-created by the pipeline.\n\n" +
        "  Where applicable, default values will be used for sample-specific metadata\n" +
        "  such as strandedness, controls etc as this information is not provided\n" +
        "  in a standardised manner when uploading data to Synapse.\n" +
        "==================================================================================="
}

//
// Obtain Sample ID from File Name
//
def synapseSampleNameFromFastQ(input_file, pattern) {

    def sampleids = ""

    def filePattern = pattern.toString()
    int p = filePattern.lastIndexOf('/')
        if( p != -1 )
            filePattern = filePattern.substring(p+1)

    input_file.each {
        String fileName = input_file.getFileName().toString()

        String indexOfWildcards = filePattern.findIndexOf { it=='*' || it=='?' }
        String indexOfBrackets = filePattern.findIndexOf { it=='{' || it=='[' }
        if( indexOfWildcards==-1 && indexOfBrackets==-1 ) {
            if( fileName == filePattern )
                return actual.getSimpleName()
            throw new IllegalArgumentException("Not a valid file pair globbing pattern: pattern=$filePattern file=$fileName")
        }

        int groupCount = 0
        for( int i=0; i<filePattern.size(); i++ ) {
            def ch = filePattern[i]
            if( ch=='?' || ch=='*' )
                groupCount++
            else if( ch=='{' || ch=='[' )
                break
        }

        def regex = filePattern
                .replace('.','\\.')
                .replace('*','(.*)')
                .replace('?','(.?)')
                .replace('{','(?:')
                .replace('}',')')
                .replace(',','|')

        def matcher = (fileName =~ /$regex/)
        if( matcher.matches() ) {
            int c=Math.min(groupCount, matcher.groupCount())
            int end = c ? matcher.end(c) : ( indexOfBrackets != -1 ? indexOfBrackets : fileName.size() )
            def prefix = fileName.substring(0,end)
            while(prefix.endsWith('-') || prefix.endsWith('_') || prefix.endsWith('.') )
                prefix=prefix[0..-2]
            sampleids = prefix
        }
    }
    return sampleids
}