#!/bin/bash

[ -f ./path.sh ] && . ./path.sh; # source the path.

# the graph should match the lm_small language model
graph_name=graph_FullNBest_lv_3gpr
# under model_root, a BN and CTS subdir are expected, each with a tri3 and tri3_fmmi_b0.1 subdir
model_root=$KALDI_ROOT/egs/DutchASR/exp/CGN_nl
lm_small=$KALDI_ROOT/egs/DutchASR/data/lang_FullNBest_lv_3gpr
lm_large=$KALDI_ROOT/egs/DutchASR/data/lang_FullNBest_lv_4g_pr10_const

# create symlinks to the scripts
if [ ! -h steps ]; then
    ln -s $KALDI_ROOT/egs/wsj/s5/steps steps
fi

if [ ! -h utils ]; then
    ln -s $KALDI_ROOT/egs/wsj/s5/utils utils
fi

# create symlinks to the models
for model_sub in BN CTS; do
    for model in tri3 tri3_fmmi_b0.1; do
        if [ $model = "tri3" ]; then tgtmodel=fmllr; else tgtmodel=fmmi; fi
        mkdir -p models/$model_sub
        if [ ! -h models/$model_sub/$tgtmodel ]; then
            ln -s $model_root/$model_sub/$model models/$model_sub/$tgtmodel
        fi
        if [ ! -h models/$model_sub/$tgtmodel/graph_3gpr ]; then
            ln -s $model_root/$model_sub/$model/$graph_name $model_root/$model_sub/$model/graph_3gpr
        fi
    done
done

mkdir -p models/LM
if [ ! -h models/LM/3gpr ]; then
    ln -s $lm_small models/LM/3gpr
fi
if [ ! -h models/LM/4gpr_const ]; then
    ln -s $lm_large models/LM/4gpr_const
fi
