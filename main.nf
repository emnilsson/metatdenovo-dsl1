#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/metatdenovo
========================================================================================
 nf-core/metatdenovo Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/metatdenovo
----------------------------------------------------------------------------------------
*/

def json_schema = "$projectDir/nextflow_schema.json"
if (params.help) {
    def command = "nextflow run nf-core/metatdenovo --input 'reads/*_R{1,2}*.fastq.gz' --assembler megahit -profile docker"
    log.info Schema.params_help(workflow, params, json_schema, command)
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

params.outdir = 'results/'

// Assembly program
ASSEMBLERS = [ megahit: true, rnaspades: true, trinity: true ]
params.assembler = '' // Set to megahit, rnaspades or trinity to be meaningful

// Modify when we start to support starting from an already finished assembly
if ( ! params.assembly && ! ASSEMBLERS[params.assembler.toLowerCase()] ) {
    println "You must choose a supported assembly program: ${ASSEMBLERS.keySet().join(', ')}"
    exit 1
}

// Annotation/gene calling program
ANNOTATORS = [ prokka: true, trinotate: true ]
params.annotator = '' // Set to prokka or trinotate to be meaningful

// Modify when we start to support starting from an already finished assembly
if ( ! ANNOTATORS[params.annotator.toLowerCase()] ) {
    println "You must choose a supported annotation program: ${ANNOTATORS.keySet().join(', ')}"
    exit 1
}

// Create a channel for the params.eukulele_dbdir if set, to make sure it's mounted
if ( params.eukulele_dbdir ) {
    ch_eukulele_dbdir = Channel.fromPath(params.eukulele_dbdir)
}
else {
    ch_eukulele_dbdir = Channel.fromPath('.')
}

// Turn bbmap false when skip_bbmap set to true, else keep the value
params.bbmap = params.skip_bbmap ? false : params.bbmap

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$projectDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$projectDir/docs/images/", checkIfExists: true)

if ( params.megan_taxonomy ) {
    ch_megan_acc2taxa        = Channel.fromPath(params.megan_acc2taxa_map,        checkIfExists: true)
    ch_megan_acc2eggnog      = Channel.fromPath(params.megan_acc2eggnog_map,      checkIfExists: true)
    ch_megan_acc2interpro2go = Channel.fromPath(params.megan_acc2interpro2go_map, checkIfExists: true)
}

/*
 * Create a channel for input read files
 */
if (params.input_paths) {
    if (params.single_end) {
        Channel
            .from(params.input_paths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.input_paths was empty - no input files supplied" }
            .into { ch_read_files_fastqc; ch_read_files_trimming }
    } else {
        Channel
            .from(params.input_paths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.input_paths was empty - no input files supplied" }
            .into { ch_read_files_fastqc; ch_read_files_trimming }
    }
} else {
    Channel
        .fromFilePairs(params.input, size: params.single_end ? 1 : 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.input}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
        .into { ch_read_files_fastqc; ch_read_files_trimming }
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Input']            = params.input
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-metatdenovo-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/metatdenovo Workflow Summary'
    section_href: 'https://github.com/nf-core/metatdenovo'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    label 'process_low'
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
        file 'software_versions_mqc.yaml' into ch_software_versions_yaml
        file "software_versions.csv"

    script:
        """
        echo $workflow.manifest.version > v_pipeline.txt
        echo $workflow.nextflow.version > v_nextflow.txt
        fastqc --version > v_fastqc.txt
        multiqc --version > v_multiqc.txt
        cutadapt --version > v_cutadapt.txt
        trim_galore --version | grep version > v_trim_galore.txt
        megahit --version > v_megahit.txt
        rnaspades.py -v > v_rnaspades.txt
        grep "my \\+\\\$VERSION" \$(which Trinity) |grep -v "#"|sed 's/.*"\\(.*\\)"; */\\1/' > v_trinity.txt
        prokka -v 2> v_prokka.txt
        TransDecoder.LongOrfs --version > v_transdecoder.txt
        diamond version > v_diamond.txt
        grep 'Last modified' \$(which bbmap.sh) > v_bbmap.txt
        featureCounts -v 2>&1|grep feature > v_featureCounts.txt
        R --version|grep '^R version' > v_R.txt
        normalize-by-median.py --version 2>&1|grep ^khmer > v_khmer.txt
        EUKulele --version | grep 'The current' > v_eukulele.txt
        emapper.py --version | grep '^emapper' > v_emapper.txt
        scrape_software_versions.py &> software_versions_mqc.yaml
        """
}

/*
 * STEP 1 - FastQC
 */
if ( ! params.skip_fastqc ) {
    process fastqc {
        tag "$name"
        label 'process_medium'
        publishDir "${params.outdir}/fastqc", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                    }

        input:
            set val(name), file(reads) from ch_read_files_fastqc

        output:
            file "*_fastqc.{zip,html}" into ch_fastqc_results

        script:
            """
            fastqc --quiet --threads $task.cpus $reads
            """
    }
} else {
    Channel.empty().set { ch_fastqc_results }
}

/*
 * STEP 2 - MultiQC
 */
if ( ! params.skip_fastqc ) {
    process multiqc {
        label 'process_medium'
        publishDir "${params.outdir}/MultiQC", mode: params.publish_dir_mode

        input:
            file (multiqc_config) from ch_multiqc_config
            file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
            // TODO nf-core: Add in log files from your new processes for MultiQC to find!
            // I need to learn a bit about that!
            file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
            file ('software_versions/*') from ch_software_versions_yaml.collect()
            file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

        output:
            file "*multiqc_report.html" into ch_multiqc_report
            file "*_data"
            file "multiqc_plots"

        script:
            rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
            rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
            custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
            // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
            """
            multiqc -f $rtitle $rfilename $custom_config_file .
            """
    }
} else {
    Channel.empty().set { ch_multiqc_report }
}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    label 'process_low'
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
        file output_docs from ch_output_docs
        file images from ch_output_docs_images

    output:
        file "results_description.html"

    script:
        """
        markdown_to_html.py $output_docs -o results_description.html
        """
}

/*
 * STEP 4a: Trimming
 */
if ( ! params.skip_trimming ) {
    process trim_galore {
        label 'process_medium'
        tag "$name"

        publishDir("${params.outdir}/trimming_logs/", mode: "copy", pattern: "*.trim_galore.log")

        input:
            tuple name, file(reads) from ch_read_files_trimming

        output:
            file("*_1.fq.gz") into ch_trimmed_fwd_reads
            file("*_2.fq.gz") into ch_trimmed_rev_reads
            tuple name, '*.fq.gz' into ch_trimmed_reads
            tuple name, '*.fq.gz' into ch_read_files_bbmap
            tuple val(name), file("*.trim_galore.log") into trimming_logs

        // TODO: Check how to best get this into fastqc/multiqc
        //file "*_fastqc.{zip,html}" into trimgalore_fastqc_reports

        """
        trim_galore --paired --fastqc --gzip --quality 20 $reads 2>&1 > ${name}.trim_galore.log
        """
    }
} 
else {
    // This is perhaps not the best way, but I couldn't come up with anything else
    // that gathered all forward reads in one channel and all reverse in another.
    process skip_trimming {
        label 'process_low'
        tag "$name"

        input:
            tuple name, file(reads) from ch_read_files_trimming

        output:
            file("*_R1_untrimmed.fastq.gz") into ch_trimmed_fwd_reads
            file("*_R2_untrimmed.fastq.gz") into ch_trimmed_rev_reads
            tuple name, '*.fastq.gz' into ch_trimmed_reads
            tuple name, '*.fastq.gz' into ch_read_files_bbmap

        """
        mv ${reads[0]} ${name}._R1_untrimmed.fastq.gz
        mv ${reads[1]} ${name}._R2_untrimmed.fastq.gz
        """
    }
}

/*
 * STEP 4b: Interleave
 */
process interleave {
    label 'process_low'
    tag "$name"

    input:
        tuple name, file(reads) from ch_trimmed_reads

    output:
        path '*.intl.fastq.gz' into ch_interleaved

    script:
        """
        reformat.sh in1=${reads[0]} in2=${reads[1]} out=${name}.intl.fastq.gz
        """
}

/*
 * STEP 4c: Digital normalization
 */
if ( params.diginorm ) {
    process diginorm {
        label 'process_medium'

        publishDir("${params.outdir}/diginorm/", mode: "copy")

        input:
            path intlreads from ch_interleaved.collect()

        output:
            path 'diginorm.out'
            path 'diginorm.*.[ps]e.fastq.gz'
            path "diginorm.C${params.diginorm_C2}k${params.diginorm_k}.pe.fastq.gz" into ch_intl_assembly
            path "diginorm.C${params.diginorm_C2}k${params.diginorm_k}.se.fastq.gz" into ch_se_assembly

        script:
            """
            normalize-by-median.py -M ${task.memory.toGiga()}e9 -p -k $params.diginorm_k -C $params.diginorm_C1 --gzip --savegraph diginorm.C${params.diginorm_C1}k${params.diginorm_k}.kh -o diginorm.C${params.diginorm_C1}k${params.diginorm_k}.pe.fastq.gz $intlreads 
            filter-abund.py -V diginorm.C${params.diginorm_C1}k${params.diginorm_k}.kh --gzip -o diginorm.C${params.diginorm_C1}k${params.diginorm_k}.fa.mixed.fastq.gz diginorm.C${params.diginorm_C1}k${params.diginorm_k}.pe.fastq.gz 
            extract-paired-reads.py --output-paired diginorm.C${params.diginorm_C1}k${params.diginorm_k}.fa.pe.fastq.gz --output-single diginorm.C${params.diginorm_C1}k${params.diginorm_k}.fa.se.fastq.gz diginorm.C${params.diginorm_C1}k${params.diginorm_k}.fa.mixed.fastq.gz 
            normalize-by-median.py -M ${task.memory.toGiga()}e9 -p -C $params.diginorm_C2 -k $params.diginorm_k --savegraph normC${params.diginorm_C2}k${params.diginorm_k}.kh --gzip -o diginorm.C${params.diginorm_C2}k${params.diginorm_k}.pe.fastq.gz diginorm.C${params.diginorm_C1}k${params.diginorm_k}.fa.pe.fastq.gz 
            normalize-by-median.py -M ${task.memory.toGiga()}e9 -C $params.diginorm_C2 -k $params.diginorm_k --loadgraph normC${params.diginorm_C2}k${params.diginorm_k}.kh --gzip -o diginorm.C${params.diginorm_C2}k${params.diginorm_k}.se.fastq.gz diginorm.C${params.diginorm_C1}k${params.diginorm_k}.fa.se.fastq.gz 
            cp .command.log diginorm.out
            """
    }
}
else {
    ch_intl_assembly = ch_interleaved.collect()
}

/*
 * STEP 5a: Make sure a user provided assembly file is gzipped. (Downstream steps require that.)
 */
if ( params.assembly ) {
    ch_assembly = Channel.fromPath(params.assembly, checkIfExists: true)

    process gzip_assembly {
        label 'process_medium'

        input:
            path assembly from ch_assembly

        output:
            path('*.gz', includeInputs: true) into ch_contigs_transdecoder
            path('*.gz', includeInputs: true) into ch_contigs_prokka
            path('*.gz', includeInputs: true) into ch_contigs_bbmap

        script:
            if ( assembly.getExtension() != 'gz' )
                """
                pigz -cp $task.cpus $assembly > $assembly.gz
                """
            else
                """
                echo done
                """
    }
}

/*
 * STEP 5b: Megahit assembly
 */
else if ( params.assembler.toLowerCase() == 'megahit' ) {
    process megahit {
        label 'process_high'
        publishDir("${params.outdir}/megahit", mode: "copy")

        input:
            file intlreads from ch_intl_assembly

        output:
            file "megahit.final.contigs.fna.gz" into ch_contigs_transdecoder
            file "megahit.final.contigs.fna.gz" into ch_contigs_prokka
            file "megahit.final.contigs.fna.gz" into ch_contigs_bbmap
            file "megahit.log"
            file "megahit.tar.gz"

        script:
            """
            megahit -t ${task.cpus} -m ${task.memory.toBytes()} --12 ${intlreads.join(',')} > megahit.log 2>&1
            cp megahit_out/final.contigs.fa megahit.final.contigs.fna
            pigz -p ${task.cpus} megahit.final.contigs.fna
            tar cfz megahit.tar.gz megahit_out/
            """
    }
}

/*
 * STEP 5c: rnaSPADES assembly
 */
else if ( params.assembler.toLowerCase() == 'rnaspades' ) {
    process rnaspades {
        label 'process_high'
        publishDir("${params.outdir}/rnaspades", mode: "copy")

        input:
            file intlreads from ch_intl_assembly

        output:
            file "rnaspades.transcripts.fna.gz" into ch_contigs_transdecoder
            file "rnaspades.transcripts.fna.gz" into ch_contigs_prokka
            file "rnaspades.transcripts.fna.gz" into ch_contigs_bbmap
            file "rnaspades.log"
            file "rnaspades.tar.gz"

        script:
            """
            rnaspades.py -t ${task.cpus} -m ${task.memory.toGiga()} ${intlreads.withIndex().collect { item, index -> "--pe-12 ${index} $item"}.join(' ')} -o rnaspades_out > rnaspades.log 2>&1
            sed 's/\\(>NODE_[0-9]*\\).*/\\1/' rnaspades_out/transcripts.fasta | pigz -cp ${task.cpus} > rnaspades.transcripts.fna.gz
            tar cfz rnaspades.tar.gz rnaspades_out/
            """
    }
}

/*
 * STEP 5d: Trinity assembly
 */
else if ( params.assembler.toLowerCase() == 'trinity' ) {
    process trinity {
        label 'process_high'
        publishDir("${params.outdir}/trinity", mode: "copy")

        input:
            file intlreads from ch_intl_assembly

        output:
            file "trinity.final.contigs.fna.gz" into ch_contigs_transdecoder
            file "trinity.final.contigs.fna.gz" into ch_contigs_prokka
            file "trinity.final.contigs.fna.gz" into ch_contigs_bbmap
            file "trinity.log"
            file "trinity.tar.gz"

        script:
            """
            for f in $intlreads; do split-paired-reads.py -1 \$(basename \$f .intl.fastq.gz).R1.fastq -2 \$(basename \$f .intl.fastq.gz).R2.fastq \$f; done
            cat *.R1.fastq > fwdreads.fastq
            cat *.R2.fastq > revreads.fastq
            Trinity --CPU ${task.cpus} --seqType fq --max_memory ${task.memory.toGiga()}G --left fwdreads.fastq --right revreads.fastq > trinity.log 2>&1
            cp trinity_out_dir/Trinity.fasta trinity.final.contigs.fna
            pigz -p ${task.cpus} trinity.final.contigs.fna
            tar cfz trinity.tar.gz trinity_out_dir/
            """
    }
}

/*
 * STEP 6a Annotation with Prokka
 */
if ( params.annotator.toLowerCase() == 'prokka' ) {
    process prokka {
        label 'process_high'
        publishDir("${params.outdir}", mode: "copy")

        input:
            file contigs from ch_contigs_prokka

        output:
            file 'prokka/*.err.gz'
            file 'prokka/*.faa.gz' into ch_emapper
            file 'prokka/*.faa.gz' into ch_diamond_refseq
            file 'prokka/*.faa.gz' into ch_eukulele
            file 'prokka/*.ffn.gz'
            file 'prokka/*.fna.gz'
            file 'prokka/*.fsa.gz'
            file 'prokka/*.gbk.gz'
            file 'prokka/*.gff.gz' into ch_gff_bbmap
            file 'prokka/*.log.gz'
            file 'prokka/*.sqn.gz'
            file 'prokka/*.tbl.gz'
            file 'prokka/*.tsv.gz'
            file 'prokka/*.txt.gz'
            val  'ID'              into ch_id_bbmap

        script:
            prefix = contigs.toString() - '.fna.gz'
            """
            unpigz -c -p $task.cpus $contigs > contigs.fna
            prokka --cpus $task.cpus --outdir prokka --prefix $prefix contigs.fna
            pigz -p $task.cpus prokka/*
            """
    }
} 

/*
 * STEP 6b ORF calling with TransDecoder.*
 */
if ( params.annotator.toLowerCase() == 'trinotate' ) {
    process transdecoder {
        label 'process_long'
        publishDir("${params.outdir}/trinotate", mode: "copy")

        input:
            file contigs from ch_contigs_transdecoder

        output:
            file '*.transdecoder.faa.gz'  into ch_emapper
            file '*.transdecoder.faa.gz'  into ch_diamond_refseq
            file '*.transdecoder.faa.gz'  into ch_eukulele
            file '*.transdecoder.gff3.gz' into ch_gff_bbmap
            file '*.transdecoder.bed.gz'
            file '*.transdecoder.fna.gz'
            val  'ID'                     into ch_id_bbmap

        script:
            """
            TransDecoder.LongOrfs -t $contigs
            TransDecoder.Predict -t $contigs
            mv *.pep \$(basename *.pep .pep).faa
            mv *.cds \$(basename *.cds .cds).fna
            pigz -p $task.cpus *.transdecoder.*
            """
    }
}

/*
 * STEP 6 - EGGNOG-mapper.
 */
if ( params.emapper && ! params.eggnogdb ) {
    process download_eggnogdb {
        label 'process_long'
        publishDir("${params.outdir}/eggnogdb", mode: "copy")

        output:
            path 'eggnog.db'            into ch_eggnogdb
            path 'eggnog.taxa.db'       into ch_eggnog_taxa
            path 'eggnog_proteins.dmnd' into ch_eggnog_proteins

        script:
            """
            download_eggnog_data.py --data_dir . -y
            """
    }
} else if ( params.emapper ) {
    ch_eggnogdb        = Channel.fromPath("$params.eggnogdb/eggnog.db",            checkIfExists: true)
    ch_eggnog_proteins = Channel.fromPath("$params.eggnogdb/eggnog_proteins.dmnd", checkIfExists: true)
    ch_eggnog_taxa     = Channel.fromPath("$params.eggnogdb/eggnog.taxa.db",       checkIfExists: true)
    ch_dwnl_eggnog = Channel.empty()
} 


if ( params.emapper ) {
    process emapper {
        label 'process_high'
        publishDir("${params.outdir}/emapper", mode: "copy")

        input:
            file orfs            from ch_emapper
            file eggnogdb        from ch_eggnogdb
            file eggnog_proteins from ch_eggnog_proteins
            file eggnog_taxa     from ch_eggnog_taxa

        output:
            file 'emapper.out'
            file '*.emapper.annotations'    into ch_emapper_annots
            file '*.emapper.seed_orthologs'

        script:
            prefix = orfs.toString() - '.faa'
            """
            which emapper.py
            emapper.py --cpu ${task.cpus} --data_dir . -i $orfs --output $prefix 2>&1 > emapper.out
            """
    }
}

/*
 * STEP 7a - Taxonomic annotation with Diamond/RefSeq and MEGAN.
 */
if ( params.megan_taxonomy ) {

    // Prioritize using user provided Diamond Refseq database in dmnd format
    if ( params.refseq_dmnd ) {
        ch_refseq_dmnd = Channel.fromPath(params.refseq_dmnd,  checkIfExists: true)
        ch_refseq_faa = Channel.empty()
    } 
    // Second best, user provide faa file
    else if ( params.refseq_faa ) {
        ch_refseq_faa  = Channel.fromPath(params.refseq_faa, checkIfExists: true)

    } 
    // Last resort: Download Refseq
    else {
        process download_refseq {
            label 'process_long'
            publishDir("${params.outdir}/refseq", mode: "copy")

            output:
                path 'refseq_protein.faa' into ch_refseq_faa

            script:
                """
                wget -A "refseq_protein.*.tar.gz" --mirror ftp://ftp.ncbi.nih.gov/blast/db
                ( cd ftp.ncbi.nih.gov/blast/db; for f in refseq_protein.*.tar.gz; do echo "--> untarring \$f <--"; tar xzf \$f; done )
                blastdbcmd -db ftp.ncbi.nih.gov/blast/db/refseq_protein -entry all -dbtype prot -out refseq_protein.faa
                """
        }
    }

    if ( ! params.refseq_dmnd ) {
        // Format a fasta file to Diamond dmnd
        process refseq_dmnd {
            label 'process_medium'
            publishDir("${params.outdir}/refseq", mode: "copy")

            input:
                file refseq_faa from ch_refseq_faa

            output:
                file 'refseq_protein.dmnd' into ch_refseq_dmnd

            script:
                if ( refseq_faa.getExtension() == 'gz' ) {
                    """
                    gunzip -c $refseq_faa | diamond makedb -d refseq_protein --threads $task.cpus
                    """
                } 
                else if ( refseq_faa.getExtension() == 'bz2' ) {
                    """
                    bunzip2 -c $refseq_faa | diamond makedb -d refseq_protein --threads $task.cpus
                    """
                } 
                else {
                    """
                    diamond makedb --in $refseq_faa -d refseq_protein --threads $task.cpus
                    """
                }
        }
    }

    process diamond_refseq {
        label 'process_high'
        publishDir("${params.outdir}/diamond-megan", mode: "copy")

        input:
            file orfs from ch_diamond_refseq
            file db   from ch_refseq_dmnd

        output:
            file '*.refseq.daa' into ch_refseq_daa

        script:
            """
            diamond blastp --threads $task.cpus -f 100 -d ${db.baseName} --query $orfs -o ${orfs.baseName}.refseq.daa
            """
    }

    process meganize {
        label 'process_low'
        publishDir("${params.outdir}/diamond-megan", mode: "copy")

        input:
            file daa             from ch_refseq_daa
            file acc2taxa        from ch_megan_acc2taxa
            file acc2eggnog      from ch_megan_acc2eggnog
            file acc2interpro2go from ch_megan_acc2interpro2go

        output:
            path('*.abin', includeInputs: true)
            file daa into ch_meganized_daa

        script:
            // This will clearly break when Megan is updated
            unzip  = ( acc2taxa.getExtension()        == 'zip' ) ? "unzip $acc2taxa" : ""
            unzip += ( acc2eggnog.getExtension()      == 'zip' ) ? "; unzip $acc2eggnog" : ""
            unzip += ( acc2interpro2go.getExtension() == 'zip' ) ? "; unzip $acc2interpro2go" : ""
            """
            $unzip
            /opt/conda/envs/nf-core-metatdenovo-1.0dev/opt/megan-6.12.3/tools/daa-meganizer \
              --in $daa \
              --longReads \
              --acc2taxa ${acc2taxa.toString() - '.zip'} \
              --acc2eggnog ${acc2eggnog.toString() - '.zip'} \
              --acc2interpro2go ${acc2interpro2go.toString() - '.zip'}
            """
    }

    process megan_export {
        label 'process_low'
        publishDir("${params.outdir}/diamond-megan", mode: "copy")

        input:
            file daa             from ch_meganized_daa

        output:
            file '*.tsv.gz'
            path '*.reads2taxonids.tsv.gz' into ch_megan_taxonomy_ncbi
            path '*.reads2taxonids.tsv.gz' into ch_megan_taxonomy_gtdb

        script:
            // This will clearly break when Megan is updated
            """
            /opt/conda/envs/nf-core-metatdenovo-1.0dev/opt/megan-6.12.3/tools/daa2info -i $daa -r2c Taxonomy    | gzip -c > ${daa.toString() - '.daa'}.reads2taxonids.tsv.gz
            /opt/conda/envs/nf-core-metatdenovo-1.0dev/opt/megan-6.12.3/tools/daa2info -i $daa -r2c EGGNOG      | gzip -c > ${daa.toString() - '.daa'}.reads2eggnogs.tsv.gz
            /opt/conda/envs/nf-core-metatdenovo-1.0dev/opt/megan-6.12.3/tools/daa2info -i $daa -r2c INTERPRO2GO | gzip -c > ${daa.toString() - '.daa'}.reads2ip2go.tsv.gz
            """
    }
}

if ( params.eukulele ) {
    process eukulele {
        label 'process_high'
        publishDir("${params.outdir}/eukulele", mode: "copy")

        input:
            path faafile from ch_eukulele
            path db      from ch_eukulele_dbdir

        output:
            path 'output/taxonomy_estimation/metat-estimated-taxonomy.out' into ch_eukulele_taxonomy
            path 'output/taxonomy_counts/output_all_*_counts.csv'
            path 'output/log/*'
            path 'output/mets_full/diamond/metat.diamond.out.gz'

        script:
            """
            unpigz -cp ${task.cpus} $faafile > metat.faa
            EUKulele -d ${params.eukulele} -m mets ${params.eukulele_dbdir ? "--reference_dir ${params.eukulele_dbdir}" : ' '} --CPUs ${task.cpus} --sample_dir . || rc=\$? 
            # EUKulele sometimes exits with 1, despite finishing OK, so we keep the return code and exit with 0 if 1 or lower
            echo "EUKulele done, rc: \$rc"
            pigz -p ${task.cpus} output/mets_full/diamond/metat.diamond.out
            if [ \$rc -le 1 ]; then exit 0; else exit \$rc; fi
            """
    }
}

/*
 * STEP 8a - quantification with BBMap
 */
process bbmap {
    label 'process_high'
    tag "$name"
    publishDir("${params.outdir}/bbmap", mode: "copy")

    when:
        params.bbmap

    input:
        path contigs from ch_contigs_bbmap
        tuple name, file(reads) from ch_read_files_bbmap

    output:
        path "${name}.bbmap.bam" into ch_bbmap_bam_fc
        tuple name, file("${name}.bbmap.bam") into ch_bbmap_bam_fs
        tuple name, file("${name}.bbmap.bam") into ch_bbmap_bam_is
        path "${name}.bbmap.out"
        //path '*.bai'

    script:
        // The trimreaddescriptions=t is required by featureCount
        """
        bbmap.sh -Xmx${task.memory.getGiga()}g trimreaddescriptions=t unpigz=t threads=$task.cpus nodisk=t ref=$contigs in=${reads[0]} in2=${reads[1]} out=stdout 2>${name}.bbmap.out | samtools view -Sb | samtools sort > ${name}.bbmap.bam
        """
}

process bbmap_feature_count {
    label 'process_high'
    publishDir("${params.outdir}/bbmap", mode: "copy")

    when:
        params.bbmap

    input:
        val  id   from ch_id_bbmap
        path gff  from ch_gff_bbmap
        path bams from ch_bbmap_bam_fc.collect()

    output:
        path 'bbmap.fc.CDS.tsv.gz' into ch_bbmap_fc
        path 'bbmap.fc.out'

    script:
        """
        unpigz -c -p $task.cpus $gff > ${gff.baseName}
        featureCounts -T $task.cpus -t CDS -g $id -a ${gff.baseName} $bams -o bbmap.fc.CDS.tsv 2>&1 > bbmap.fc.out
        pigz -p $task.cpus bbmap.fc.CDS.tsv
        """
}

process bbmap_flagstat {
    tag "$name"
    label 'process_medium'
    publishDir("${params.outdir}/bbmap", mode: "copy")

    input:
        tuple name, file(bam) from ch_bbmap_bam_fs

    output:
        path '*.flagstat' into ch_bbmap_fs

    script:
        """
        samtools flagstat $bam > ${name}.flagstat
        """
}

process bbmap_idxstat {
    tag "$name"
    label 'process_medium'
    publishDir("${params.outdir}/bbmap", mode: "copy")

    input:
        tuple name, file(bam) from ch_bbmap_bam_is

    output:
        path '*.idxstat.gz' into ch_bbmap_is

    script:
        """
        samtools idxstat $bam | gzip -c > ${name}.idxstat.gz
        """
}

/*
 * STEP 9 - make summary tables
 */

if ( params.summary ) {
    if ( params.bbmap ) {
        // Summarise overall mapping to contigs from idxstats files
        process sum_bbmap {
            label 'process_high'
            publishDir("${params.outdir}/summary", mode: "copy")

            input:
                path idxs from ch_bbmap_is.collect()

            output:
                path 'bbmap_idxstats.tsv.gz'
                path 'bbmap_overall.tsv.gz'

            script:
                """
                #!/usr/bin/env Rscript
                library(data.table)
                library(dtplyr)
                library(dplyr, warn.conflicts = FALSE)
                setDTthreads($task.cpus)
                idxst <- data.table(seqname = character(), seqlen = integer(), n_mapped = integer(), n_unmapped = integer(), sample = character())
                for ( f in c('${idxs.join("','")}') ) {
                    s <- sub('.idxstat.gz', '', f)
                    t <- fread(f, col.names = c('seqname', 'seqlen', 'n_mapped', 'n_unmapped'))
                    t\$sample <- s
                    idxst <- funion(idxst, t)
                }
                fwrite(idxst, 'bbmap_idxstats.tsv.gz', sep = '\t', row.names = FALSE, quote = FALSE)
                lazy_dt(idxst) %>%
                  group_by(sample) %>% summarise(n_mapped = sum(n_mapped), n_unmapped = sum(n_unmapped)) %>% ungroup() %>%
                  as.data.table() %>%
                  fwrite('bbmap_overall.tsv.gz', sep = '\t', row.names = FALSE, quote = FALSE)
                """
        }

        // Summarise ORF counts
        process sum_bbmap_counts {
            label 'process_high'
            publishDir("${params.outdir}/summary", mode: "copy")

            input:
                path bbmapfc from ch_bbmap_fc

            output:
                path 'bbmap_counts.tsv.gz'

            script:
                """
                #!/usr/bin/env Rscript
                library(data.table)
                library(dtplyr)
                library(dplyr, warn.conflicts = FALSE)
                setDTthreads($task.cpus)
                fread('$bbmapfc') %>%
                    melt(measure.vars = 7:ncol(.), variable.name = 'sample', value.name = 'count') %>% lazy_dt() %>%
                    mutate(sample = stringr::str_remove(sample, '.bbmap.bam'), r = count/Length) %>%
                    group_by(sample) %>% mutate(tpm = r/sum(r) * 1e6) %>% ungroup() %>%
                    select(-r) %>% as.data.table() %>%
                    fwrite('bbmap_counts.tsv.gz', sep = '\t', row.names = FALSE)
                """
        }
    }

    if ( params.megan_taxonomy ) {
        if ( params.ncbitaxonomy ) {
            ch_ncbi_taxonomy = Channel.fromPath(params.ncbitaxonomy)
        }
        else {
            ch_ncbitax_tar = Channel.fromPath(params.ncbitaxonomy_targz)

            process create_ncbi_taxonomy {
                label 'process_medium'
                publishDir("${params.outdir}/ncbi_taxonomy", mode: "copy")

                input:
                    path taxtar from ch_ncbitax_tar

                output:
                    path 'ncbi_taxonomy.tsv.gz' into ch_ncbi_taxonomy

                script:
                    """
                    tar xzf $taxtar
                    make_taxflat.R nodes.dmp names.dmp ncbi_taxonomy.tsv.gz
                    """
            }
        }
        process megan_ncbi_full_taxonomy {
            label 'process_low'
            publishDir("${params.outdir}/summary", mode: "copy")

            input:
                path megantaxa from ch_megan_taxonomy_ncbi
                path ncbi_taxflat from ch_ncbi_taxonomy

            output:
                path 'megan_refseq_ncbi_taxonomy.tsv.gz'

            script:
                """
                #!/usr/bin/env Rscript
                library(data.table)
                library(dtplyr)
                library(dplyr, warn.conflicts = FALSE)
                setDTthreads($task.cpus)
                fread('$megantaxa', col.names = c('orf', 'tax_id')) %>% lazy_dt() %>%
                  left_join(fread('$ncbi_taxflat') %>% lazy_dt(), by = 'tax_id') %>%
                  as.data.table() %>%
                  fwrite('megan_refseq_ncbi_taxonomy.tsv.gz', sep = '\t', row.names = FALSE)
                """
        }

        if ( params.gtdb_taxonomy ) {
            ch_gtdb_taxonomy = Channel.fromPath(params.gtdb_taxonomy)
        }
        else {
            ch_arctar = Channel.fromPath(params.gtdb_archaea_metadata_targz)
            ch_bactar = Channel.fromPath(params.gtdb_bacteria_metadata_targz)

            process gtdb_taxtable {
                label 'process_low'
                publishDir("${params.outdir}/gtdb", mode: "copy")

                input:
                    path arctar from ch_arctar
                    path bactar from ch_bactar

                output:
                    path 'gtdb_taxonomy.tsv.gz' into ch_gtdb_taxonomy

                script:
                    """
                    #!/usr/bin/env Rscript
                    library(data.table)
                    library(dplyr, warn.conflicts = FALSE)
                    setDTthreads($task.cpus)
                    # Read and stack the archeal and bacterial metadata tables,
                    funion(
                      fread(cmd = 'tar xzOf $arctar', colClasses = c('character')),
                      fread(cmd = 'tar xzOf $bactar', colClasses = c('character'))
                    ) %>% 
                        as_tibble() %>%
                        # keep only the interesting fields, and remove leading rank letters from the taxonomy string
                        transmute(gtdb_accession = accession, gtdb_taxonomy = stringr::str_remove_all(gtdb_taxonomy, '[a-z]__'), ncbi_taxid) %>%
                        # separate the taxonomy string into one field per rank
                        tidyr::separate(gtdb_taxonomy, c('gtdb_domain', 'gtdb_phylum', 'gtdb_class', 'gtdb_order', 'gtdb_family', 'gtdb_genus', 'gtdb_species'), sep = ';') %>%
                        fwrite('gtdb_taxonomy.tsv.gz', sep = '\t', row.names = FALSE)
                    """
            }
        }

        process gtdb_taxonomy {
            label 'process_low'
            publishDir("${params.outdir}/summary", mode: "copy")

            input:
                path gtdbtax from ch_gtdb_taxonomy
                path megantaxa from ch_megan_taxonomy_gtdb

            output:
                path 'megan_refseq_gtdb_taxonomy.tsv.gz'

            script:
                """
                #!/usr/bin/env Rscript
                library(data.table)
                library(dtplyr)
                library(dplyr, warn.conflicts = FALSE)
                setDTthreads($task.cpus)
                fread('$megantaxa', col.names = c('orf', 'tax_id')) %>% lazy_dt() %>%
                  left_join(fread('$gtdbtax') %>% lazy_dt() %>% mutate(ncbi_taxid = as.integer(ncbi_taxid)), by = c('tax_id' = 'ncbi_taxid')) %>%
                  rename(ncbi_tax_id = tax_id) %>%
                  as.data.table() %>%
                  fwrite('megan_refseq_gtdb_taxonomy.tsv.gz', sep = '\t', row.names = FALSE)
                """
        }
    }
    if ( params.eukulele ) {
        process format_eukulele {
            label 'process_medium'
            publishDir("${params.outdir}/summary", mode: "copy")

            input:
                path euktax from ch_eukulele_taxonomy

            output:
                path "eukulele_${params.eukulele}.tsv"

            script:
                """
                #!/usr/bin/env Rscript
                library(dplyr, warn.conflicts = FALSE)
                library(tidyr)
                read.delim("$euktax", sep = '\t') %>%
                  select(-X) %>%
                  rename(orf = transcript_name, rank = classification_level, taxon = classification) %>%
                  separate(full_classification, c('domain', 'kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species'), fill = 'right', sep = '; ') %>%
                  write.table("eukulele_${params.eukulele}.tsv", sep = '\t', quote = FALSE, row.names = FALSE, na = "")
                """
        }
    }

    if ( params.emapper ) {
        process format_emapper_annots {
            label 'process_low'
            publishDir("${params.outdir}/summary", mode: "copy")

            input:
                path emapperannots from ch_emapper_annots

            output:
                path 'eggnog_annotations.tsv.gz'

            script:
                """
                #!/usr/bin/env Rscript
                library(data.table)
                library(dtplyr)
                library(dplyr, warn.conflicts = FALSE)
                setDTthreads($task.cpus)
                fread(cmd = "sed 's/^#//' $emapperannots") %>% lazy_dt() %>%
                    rename(orf = query_name) %>%
                    as.data.table() %>%
                    fwrite('eggnog_annotations.tsv.gz', sep = '\t', row.names = FALSE)
                """
        }
    }
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/metatdenovo] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/metatdenovo] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/metatdenovo] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/metatdenovo] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$projectDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$projectDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, projectDir: "$projectDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$projectDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/metatdenovo] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            if ( mqc_report.size() <= params.max_multiqc_email_size.toBytes() ) {
              mail_cmd += [ '-A', mqc_report ]
            }
            mail_cmd.execute() << email_html
            log.info "[nf-core/metatdenovo] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/metatdenovo]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/metatdenovo]${c_red} Pipeline completed with errors${c_reset}-"
    }
}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/metatdenovo v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

// vim:sw=4
