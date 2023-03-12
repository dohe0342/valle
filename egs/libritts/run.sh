#!/usr/bin/env bash

set -eou pipefail

# fix segmentation fault reported in https://github.com/k2-fsa/icefall/issues/674
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

nj=16
stage=-1
stop_stage=3

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/LibriTTS
#      You can download LibriTTS from https://www.openslr.org/60/
#

dl_dir=/home/work/workspace/LibriSpeech/tts

# dataset_parts="-p dev-clean -p test-clean"  # debug
#dataset_parts="--dataset-parts all"  # all
dataset_parts="all"  # all
#dataset_parts="train-clean-100"  # all
#dataset_parts="train-clean-360"  # all
#dataset_parts="train-other-500"  # all

max_duration=40
filter_max_duration=20

use_fp16=false
dtype="float32"

model_name="valle"
decoder_dim=1024
nhead=16
num_decoder_layers=12

accumulate_grad_steps=1
base_lr=0.05

num_epochs=10

audio_extractor="Encodec"  # or Fbank
audio_feats_dir=data/tokenized

world_size=8

exp_suffix=""

. shared/parse_options.sh || exit 1


# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "dl_dir: $dl_dir"
  log "Stage 0: Download data"

  # If you have pre-downloaded it to /path/to/LibriTTS,
  # you can create a symlink
  #
  #   ln -sfv /path/to/LibriTTS $dl_dir/LibriTTS
  #
  if [ ! -d $dl_dir/LibriTTS/dev-other ]; then
    lhotse download libritts $dl_dir
    #lhotse download libritts ${dataset_parts} $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare LibriTTS manifest"
  # We assume that you have downloaded the LibriTTS corpus
  # to $dl_dir/LibriTTS
  mkdir -p data/manifests
  if [ ! -e data/manifests/.libritts.done ]; then
    #lhotse prepare libritts ${dataset_parts} -j $nj $dl_dir/LibriTTS data/manifests
    lhotse prepare libritts -j $nj $dl_dir/LibriTTS data/manifests
    touch data/manifests/.libritts.done
  fi
fi


if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Tokenize/Fbank LibriTTS"
  mkdir -p ${audio_feats_dir}
  if [ ! -e ${audio_feats_dir}/.libritts.tokenize.done ]; then
    python3 bin/tokenizer.py --dataset-parts "${dataset_parts}" \
        --audio-extractor ${audio_extractor} \
        --src-dir "data/manifests" \
        --output-dir "${audio_feats_dir}"
  fi
  touch ${audio_feats_dir}/.libritts.tokenize.done
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Prepare LibriTTS train/dev/test"
  if [ ! -e ${audio_feats_dir}/.libritts.train.done ]; then
    if [ "${dataset_parts}" == "all" ];then
      # train
      lhotse combine \
        ${audio_feats_dir}/libritts_cuts_train-clean-100.jsonl.gz \
        ${audio_feats_dir}/libritts_cuts_train-clean-360.jsonl.gz \
        ${audio_feats_dir}/libritts_cuts_train-other-500.jsonl.gz \
        ${audio_feats_dir}/cuts_train.jsonl.gz

      # dev
      lhotse copy \
        ${audio_feats_dir}/libritts_cuts_dev-clean.jsonl.gz \
        ${audio_feats_dir}/cuts_dev.jsonl.gz
    else  # debug
      # train
      lhotse copy \
        ${audio_feats_dir}/libritts_cuts_dev-clean.jsonl.gz \
        ${audio_feats_dir}/cuts_train.jsonl.gz
      # dev
      lhotse subset --first 400 \
        ${audio_feats_dir}/libritts_cuts_test-clean.jsonl.gz \
        ${audio_feats_dir}/cuts_dev.jsonl.gz
    fi

    # test
    lhotse copy \
      ${audio_feats_dir}/libritts_cuts_test-clean.jsonl.gz \
      ${audio_feats_dir}/cuts_test.jsonl.gz

    touch ${audio_feats_dir}/.libritts.train.done
  fi
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Train ${model_name}"

  if ${use_fp16};then
    dtype="float16"
  fi

  python3 bin/trainer.py --manifest-dir ${audio_feats_dir} \
    --text-tokens ${audio_feats_dir}/unique_text_tokens.k2symbols \
    --max-duration ${max_duration} --filter-max-duration ${filter_max_duration} --dtype ${dtype} \
    --model-name "${model_name}" --norm-first true --add-prenet false \
    --decoder-dim ${decoder_dim} --nhead ${nhead} --num-decoder-layers ${num_decoder_layers} \
    --accumulate-grad-steps ${accumulate_grad_steps} --base-lr ${base_lr} \
	--num-epochs ${num_epochs} --start-epoch ${start_epoch} --start-batch 0 \
    --exp-dir exp/${model_name}${exp_suffix} \
	--world-size ${world_size}
fi
