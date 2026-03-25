# VSI to TIF Conversion

This repository converts Olympus `.vsi` whole-slide images into tiled pyramid TIFF outputs that are easier to use in downstream pathology workflows. The main conversion script is `batch_vsi_to_pyr_noimagej.sh`, and the repository also includes a Conda environment file, `msseg.yaml`, for installing the required Python and image-processing dependencies. 


## 1. Clone the repository

```bash
git clone https://github.com/JyXUU/vsi_to_tif_conversion.git
cd vsi_to_tif_conversion
```

## 2. Create the Conda environment

```bash
conda env create -f msseg.yaml
```

## 3. Run the conversion

Basic usage:

```bash
bash batch_vsi_to_pyr_noimagej.sh <VSI_DIR> <OUT_DIR>
```

Example:

```bash
bash batch_vsi_to_pyr_noimagej.sh \
  /path/to/folder/with_vsi_files \
  /path/to/output_folder
```

The script expects exactly two arguments:

- `VSI_DIR`: folder containing `*.vsi`
- `OUT_DIR`: output folder

This usage is defined in the script itself. 


## Example full workflow

```bash
# clone
git clone https://github.com/JyXUU/vsi_to_tif_conversion.git
cd vsi_to_tif_conversion

# create environment
conda env create -f msseg.yaml

# enter environment
conda activate msseg

# set tool paths if needed
export BFCONVERT=$HOME/local/bin/bftools/bfconvert
export VIPS_BIN=$(command -v vips)
export TIFFCP_BIN=$(command -v tiffcp)
export TIFFSET_BIN=$(command -v tiffset)
export PYTHON_BIN=$(command -v python)

# run conversion
bash batch_vsi_to_pyr_noimagej.sh \
  /data/vsi_input \
  /data/vsi_output
```
