#!/usr/bin/env bash

set -eou pipefail

nj=15
stage=0
stop_stage=100

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/tedlium3
#      You can find data, doc, legacy, LM, etc, inside it.
#      You can download them from https://www.openslr.org/51
#
#  - $dl_dir/musan
#      This directory contains the following directories downloaded from
#       http://www.openslr.org/17/
#
#     - music
#     - noise
#     - speech
dl_dir=$PWD/download

. shared/parse_options.sh || exit 1

# vocab size for sentence piece models.
# It will generate data/lang_bpe_xxx,
# data/lang_bpe_yyy if the array contains xxx, yyy
vocab_sizes=(
  5000
  2000
  1000
  500
)

# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download data"

  # If you have pre-downloaded it to /path/to/tedlium3,
  # you can create a symlink
  #
  # ln -sfv /path/to/tedlium3 $dl_dir/tedlium3
  #
  if [ ! -d $dl_dir/tedlium3 ]; then
    lhotse download tedlium $dl_dir
    mv $dl_dir/TEDLIUM_release-3 $dl_dir/tedlium3
  fi

  # If you have pre-downloaded it to /path/to/musan,
  # you can create a symlink
  #
  #ln -sfv /path/to/musan $dl_dir/musan

  if [ ! -d $dl_dir/musan ]; then
    lhotse download musan $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare tedlium3 manifest"
  # We assume that you have downloaded the tedlium3 corpus
  # to $dl_dir/tedlium3
  mkdir -p data/manifests
  lhotse prepare tedlium $dl_dir/tedlium3 data/manifests
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Prepare musan manifest"
  # We assume that you have downloaded the musan corpus
  # to data/musan
  mkdir -p data/manifests
  lhotse prepare musan $dl_dir/musan data/manifests
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Compute fbank for tedlium3"
  mkdir -p data/fbank
  ./local/compute_fbank_tedlium.py
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Compute fbank for musan"
  mkdir -p data/fbank
  ./local/compute_fbank_musan.py
fi

if [ $stage -le 5 ] && [ $stop_stage -ge 5 ]; then
  log "Stage 5: Prepare phone based lang"
  lang_dir=data/lang_phone
  mkdir -p $lang_dir

  if [ ! -f $lang_dir/train.text ]; then
    ./local/prepare_transcripts.py \
      --lang-dir $lang_dir \
      --manifests-dir data/manifests
  fi

  if [ ! -f $lang_dir/lexicon_words.txt ]; then
    ./local/prepare_lexicon.py \
      --lang-dir $lang_dir \
      --manifests-dir data/manifests
  fi

  (echo '!SIL SIL'; echo '<UNK> <UNK>'; ) |
    cat - $lang_dir/lexicon_words.txt |
    sort | uniq > $lang_dir/lexicon.txt

  if [ ! -f $lang_dir/L_disambig.pt ]; then
    ./local/prepare_lang.py --lang-dir $lang_dir
  fi
fi

if [ $stage -le 6 ] && [ $stop_stage -ge 6 ]; then
  log "Stage 6: Prepare BPE based lang"

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}
    mkdir -p $lang_dir
    # We reuse words.txt from phone based lexicon
    # so that the two can share G.pt later.
    cp data/lang_phone/words.txt $lang_dir

    if [ ! -f $lang_dir/transcript_words.txt ]; then
      log "Generate data for BPE training"
      cat data/lang_phone/train.text |
      cut -d " " -f 2- > $lang_dir/transcript_words.txt
      # remove the <unk> for transcript_words.txt
      sed -i 's/ <unk>//g' $lang_dir/transcript_words.txt
      sed -i 's/<unk> //g' $lang_dir/transcript_words.txt
      sed -i 's/<unk>//g' $lang_dir/transcript_words.txt
    fi

    ./local/train_bpe_model.py \
      --lang-dir $lang_dir \
      --vocab-size $vocab_size \
      --transcript $lang_dir/transcript_words.txt

    if [ ! -f $lang_dir/L_disambig.pt ]; then
      ./local/prepare_lang_bpe.py --lang-dir $lang_dir
    fi
  done
fi
