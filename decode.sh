#!/bin/bash

#
#   This script is used to decode all audio (.wav) in a source directory and produce transcriptions in a target directory
#
#   Use the configure.sh script to create symlinks to the relevant utilities of Kaldi and the models.
#
#   If the source directory contains a .ubm file, only those sections will be transcribed
#   If the source directory contains a .stm file, it is assumed to contain a transcription of the audio in the source
#   directory, and an evaluation is done using asclite. A .glm can be applied to the transcript in order to clean it up.
#
#   All source data is copied to the target directory for processing, so make sure there is enough space available in the
#   target location.
#
#   The following steps are taken:
#       1. The source directory is scanned for audio, which is then processed by the LIUM speaker diarization tool.
#           The results are used to create the files needed for Kaldi: wav.scp, segments, utt2spk, spk2utt, spk2gender
#       2. MFCC features and CMVN stats are generated. The data is split into 4 sets: Male & Female Broadcast News and
#           Telephone speech.
#       3. Decoding is done in several stages: FMLLR (2-pass), then FMMI, both using a relatively small trigram language model
#           The resulting lattices are rescored using a larger 4-gram language model.
#       4. 1-best transcriptions are extracted from the rescored lattices and results are gathered into 1Best.ctm which contains
#           the transcriptions for all of the audio in the source directory. Optionally an NBest ctm can also be generated.
#       5. If a reference transcription is available, an evaluation is done using asclite.
#

cmd=run.pl
nj=4
stage=1
num_threads=1
inv_acoustic_scale=11   # used for 1-best and N-best generation
# for decode_fmllr:
first_beam=10.0         # Beam used in initial, speaker-indep. pass
first_max_active=2000   # max-active used in initial pass.
silence_weight=0.01
max_active=7000
# for decode_fmmi:
maxactive=7000
# for decode_fmllr & decode_fmmi:
acwt=0.083333           # Acoustic weight used in getting fMLLR transforms, and also in lattice generation.
beam=13.0
lattice_beam=6.0

rnnnbest=1000
rnnweight=.5

speech_types="MS FS MT FT"
nbest=0
cts=false
rnn=false

# language models used for rescoring. smallLM must match with the graph of acoustic+language model
# largeLM must be a 'const arpa' LM
graph=graph_3gpr
smallLM=3gpr
largeLM=4gpr_const
rnntest=/Volumes/KALDI/rnntest_nce22_vocab100k_hidden320

[ -f ./path.sh ] && . ./path.sh; # source the path.

. parse_options.sh || exit 1;

if [ $# != 2 ]; then
    echo "Wrong #arguments ($#, expected 2)"
    echo "Usage: decode.sh [options] <source-dir> <decode-dir>"
    echo "  "
    echo "main options (for others, see top of script file)"
    echo "  --config <config-file>                   # config containing options"
    echo "  --nj <nj>                                # number of parallel jobs"
    echo "  --cmd <cmd>                              # Command to run in parallel with"
    echo "  --acwt <acoustic-weight>                 # default 0.08333 ... used to get posteriors"
    echo "  --num-threads <n>                        # number of threads to use, default 1."
    echo "  --speech-types <types>                   # speech types to decode, default \"MS FS MT FT\" "
    echo "  --nbest <n>                              # produce <n>-best ctms (without posteriors)"
    echo "  --cts <true/false>                       # use cts models for telephone speech, default is false."
    exit 1;
fi

## These settings should generally be left alone
result=$2
data=$2/Intermediate/Data
lmloc=models/LM
fmllr_decode=$2/Intermediate/fmllr
fmmi_decode=$2/Intermediate/fmmi
rescore=$2/Intermediate/rescore
orgrescore=$rescore
rnnrescore=$2/Intermediate/rnnrescore
symtab=$lmloc/$largeLM/words.txt
fmllr_opts="--cmd $cmd --nj $nj --skip-scoring true --num-threads $num_threads --first-beam $first_beam --first-max-active $first_max_active --silence-weight $silence_weight --acwt $acwt --max-active $max_active --beam $beam --lattice-beam $lattice_beam";
fmmi_opts="--cmd $cmd --nj $nj --skip-scoring true --num-threads $num_threads --acwt $acwt --maxactive $maxactive --beam $beam --lattice-beam $lattice_beam";
##

mkdir -p $data/ALL/liumlog $fmllr_decode $fmllr_decode.si $fmmi_decode
cp -a $1/* $data

## data prep
if [ $stage -le 1 ]; then
    ## Process source directory
    find $data -name '*.wav' >$data/test.flist
    local/flist2scp.pl $data
    cat $data/ALL/utt2spk.tmp | sort -k2,2 -k1,1 -u >$data/ALL/utt2spk
    rm $data/ALL/utt2spk.tmp $data/foo.wav
    local/change_segment_names.pl $data                                       # change names of utterances to enable sorting on 2 columns simultaneously
    if [ -e $data/fix-stm ]; then
        cat $data/*.stm | $data/fix-stm | sort -k1,1 -k4,4n >$data/ALL/ref.stm  # if there is a fix-stm module, use it
    fi
    utils/fix_data_dir.sh $data/ALL
fi

## feature generation
if [ $stage -le 2 ]; then
    ## create mfccs for decoding
    cp conf/mfcc.conf $2/Intermediate
    steps/make_mfcc.sh --nj $nj --mfcc-config $2/Intermediate/mfcc.conf $data/ALL $data/ALL/log $2/Intermediate/mfcc || exit 1;
    steps/compute_cmvn_stats.sh $data/ALL $data/ALL/log $2/Intermediate/mfcc || exit 1;
    ## and make separate folders for speech types
    for type in $speech_types; do
        cat $data/BWGender | grep $type | uniq | awk '{print $2}' >foo
        utils/subset_data_dir.sh --spk-list foo $data/ALL $data/$type
    done
    rm foo
fi

## decode
if [ $stage -le 3 ]; then
    for type in $speech_types; do
        if [[ $type == *T ]] && $cts; then bw=CTS; else bw=BN; fi
        fmllr_models=models/$bw/fmllr
        fmmi_models=models/$bw/fmmi

        echo -n "Duration of $type speech: "
        cat $data/${type}/segments | awk '{s+=$4-$3} END {printf("%.0f", s)}' | local/convert_time.sh
        time steps/decode_fmllr.sh $fmllr_opts $fmllr_models/$graph $data/$type $fmllr_models/foo
        rm -rf $fmllr_decode/$type
        rm -rf ${fmllr_decode}.si/$type
        mv -f $fmllr_models/foo $fmllr_decode/$type      # standard scripts place results in subdir of model directory..
        mv -f $fmllr_models/foo.si ${fmllr_decode}.si/$type
        time steps/decode_fmmi.sh $fmmi_opts --transform-dir $fmllr_decode/$type $fmmi_models/$graph $data/$type $fmmi_models/foo
        rm -rf $fmmi_decode/$type
        mv -f $fmmi_models/foo $fmmi_decode/$type
        time steps/lmrescore_const_arpa.sh --skip-scoring true $lmloc/$smallLM $lmloc/$largeLM $data/$type $fmmi_decode/$type $rescore/$type

        if $rnn; then
            time steps/rnnlmrescore.sh --cmd $cmd --skip-scoring true --rnnlm-ver faster-rnnlm/faster-rnnlm --N $rnnnbest --inv-acwt $inv_acoustic_scale $rnnweight $lmloc/$largeLM $rnntest $data/$type $rescore/$type $rnnrescore/$type
        fi
    done
fi

# create readable output
if [ $stage -le 4 ]; then
    if  $rnn; then
        rescore=$rnnrescore
    fi

    acoustic_scale=$(awk -v as=$inv_acoustic_scale 'BEGIN { print 1/as }')
    rm -f $data/ALL/1Best.raw.ctm
    if (( $nbest > 0 )); then
        rm -f $result/NBest.raw.ctm
    fi
    for type in $speech_types; do
        ## convert lattices into a ctm with confidence scores
        if [[ $type == *T ]] && $cts; then bw=CTS; else bw=BN; fi
        fmmi_models=models/$bw/fmmi
        numjobs=$(< $orgrescore/$type/num_jobs)

        # produce 1-Best with confidence
        $cmd --max-jobs-run $nj JOB=1:$numjobs $2/Intermediate/log/lat2ctm.$type.JOB.log \
            gunzip -c $rescore/$type/lat.JOB.gz \| \
            lattice-push ark:- ark:- \| \
            lattice-align-words $lmloc/$largeLM/phones/word_boundary.int $fmmi_models/final.mdl ark:- ark:- \| \
            lattice-to-ctm-conf --inv-acoustic-scale=$inv_acoustic_scale ark:- - \| utils/int2sym.pl -f 5 $symtab \| \
            local/ctm_time_correct.pl $data/ALL/segments \| sort \> $rescore/$type/1Best.JOB.ctm | exit 1;
        cat $rescore/$type/1Best.*.ctm >$data/$type/1Best.ctm

        ## convert lattices into an nbest-ctm (without confidence scores)
        if (( $nbest > 0 )); then
            $cmd --max-jobs-run $numjobs JOB=1:$numjobs $2/Intermediate/log/lat2nbest.JOB.log \
                gunzip -c $rescore/$type/lat.JOB.gz \| \
                lattice-to-nbest --acoustic-scale=$acoustic_scale --n=$nbest ark:- ark:- \| \
                nbest-to-ctm ark:- - \| utils/int2sym.pl -f 5 $symtab \| \
                local/ctm_time_correct.pl $data/ALL/segments \| sort \> $rescore/$type/NBest.JOB.ctm
            cat $rescore/$type/NBest.*.ctm >$data/$type/NBest.ctm
        fi
    done
    for type in MS FS MT FT; do
        if [ -e $data/$type/1Best.ctm ]; then
            cat $data/$type/1Best.ctm >>$data/ALL/1Best.raw.ctm
        fi
        if (( $nbest > 0 )) && [ -e $data/$type/NBest.ctm ]; then
            cat $data/$type/NBest.ctm >>$data/ALL/NBest.raw.ctm
        fi
    done

    # combine the ctms and do postprocessing: sort, combine numbers, restore compounds, filter with glm
    cat $data/ALL/1Best.raw.ctm | sort -k1,1 -k3,3n | \
        perl local/combine_numbers.pl | sort -k1,1 -k3,3n | local/compound-restoration.pl | \
        csrfilt.sh -s -i ctm -t hyp local/nbest-eval-2008.glm >$data/ALL/1Best.ctm
    cat $data/ALL/NBest.raw.ctm | sort -k1,1 -k3,3n | \
        perl local/combine_numbers.pl | sort -k1,1 -k3,3n | local/compound-restoration.pl | \
        csrfilt.sh -s -i ctm -t hyp local/nbest-eval-2008.glm >$data/ALL/NBest.ctm
    cp $data/ALL/1Best.ctm $result
    cp $data/ALL/NBest.ctm $result
fi

# score if reference transcription exists
if [ $stage -le 5 ]; then
    if [ -s $data/ALL/ref.stm ]; then
        # score using asclite, then produce alignments and reports using sclite
        if [ -e $data/ALL/test.uem ]; then
            uem="-uem $data/ALL/test.uem"
        fi
        asclite -D -noisg -r $data/ALL/ref.stm stm -h $result/1Best.ctm ctm $uem -o sgml
        cat $result/1Best.ctm.sgml | sclite -P -o sum -o pralign -o dtl -n $result/1Best.ctm
    fi
fi

