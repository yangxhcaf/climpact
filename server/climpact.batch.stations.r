# ------------------------------------------------
# This file contains functionality to batch process station files stored in "RClimdex format" (i.e. 6 column format, see www/sample_data/sydney_observatory_hill_1936-2015.txt for an example)
# ------------------------------------------------
#
# CALLING THIS FILE:
#    Rscript climpact.batch.stations.r /full/path/to/station/files/ /full/path/to/metadata.txt base_period_begin base_period_end cores_to_use
#    e.g. Rscript climpact.batch.stations.r ./www/sample_data/Renovados_hasta_2010 ./www/sample_data/climpact.sample.batch.metadata.txt 1971 2000 2
#
# NOTE: This file expects that all of your individual station files are kept in /directory/path/to/station/files/ and that each file name (excluding the path directory) is found in
#       column one of metadata.txt, with corresponding metadata in subsequent columns.
#
# COMMAND LINE FLAGS:
#     - /full/path/to/station/files/ : directory path to where files listed in column one of metadata.txt are kept.
#     - /full/path/to/metadata.txt : text file containing 12 columns; station file, latitude, longitude, wsdin, csdin, Tb_HDD, Tb_CDD, Tb_GDD, rx_ud, rnnmm_ud, txtn_ud, SPEI
#     - base_period_begin : beginning year of base period
#     - base_period_end : end year of base period
#     - cores_to_use : number of cores to use in parallel

# load and source and specify cores
library(foreach)
library(doSNOW)
library(climdex.pcic)
library(doParallel)
library(zoo)
library(zyp)

# return a nice list of station metadata
read.file.list.metadata <- function(metadata_filepath) {
    metadataTable <- read.table(metadata_filepath,
    header = TRUE,
    col.names = c("station_file", "latitude", "longitude", "wsdin",   "csdin",   "Tb_HDD", "Tb_CDD", "Tb_GDD", "rxnday",  "rnnmm", "txtn", "SPEI"),
    colClasses = c("character",   "real",     "real",      "integer", "integer", "real",   "real",   "real",   "integer", "real",  "real", "integer"))
  return(metadataTable)
}

strip_file_extension <- function(fileName) {
  file_parts <- strsplit(fileName, "\\.")[[1]]
  stripped <- substr(fileName, start = 1, stop = nchar(fileName) - nchar(file_parts[length(file_parts)]) - 1)
  print(paste0("input: ", fileName, " output: ", stripped))
  return(stripped)
}

# call QC and index calculation functionality for each file specified in metadata.txt
batch <- function(progress, metadata_filepath, batchfiles, base.start, base.end, batchOutputFolder) {

  batch_metadata <- read.file.list.metadata(metadata_filepath)

  if (!is.null(progress)) {
    prog_int <- 0.9 / length(batch_metadata$station_file)
  }
  # progressSNOW <- function(n) {
  #   if (interactive()) {
  #     progress$inc(prog_int)
  #   }
  # }
  # opts <- list(progress = progressSNOW)
  # registerDoSNOW(cl) # needs cl variable (cluster intialised via cl <- makeCluster(numCores))

  # batchfiles %>% tidyverse::remove_rownames %>% tidyverse::column_torownames(var=1)
  # batchfiles <- data.frame(batchfiles[,-1], row.names=batchfiles[,1])
  # set each row name in batch file to station name for indexing
  row.names(batchfiles) <- batchfiles$name
  batchfiles[1] <- NULL
  numfiles <- length(batch_metadata$station_file)
  for (file.number in 1:numfiles) {
    msg <- paste("File", file.number, "of", numfiles, ":", batch_metadata$station_file[file.number])
    print(msg)
    if (!is.null(progress)) progress$inc(detail = msg)
    #fileName = batch_metadata$station_file[file.number]
    file <- batchfiles[file.number, "datapath"]
    qc_and_calculateIndices(progress, prog_int, batch_metadata, file.number, file, base.start, base.end, batchOutputFolder)

    # progress incremented in calculations if (!is.null(progress)) progress$inc(prog_int)
  }
  zipfilename <- zipFiles(batchOutputFolder, destinationFileName = paste0(basename(batchOutputFolder), ".zip"))
  return(zipfilename)
}

qc_and_calculateIndices <- function(progress, prog_int, batch_metadata, file.number, file, base.start, base.end, baseFolder) {
  fileName <- batch_metadata$station_file[file.number]
  cat(file = stderr(), "qc_and_calculateIndices(), working on :", fileName, "\n")
  print(fileName)
  print(file)
  lat <- as.numeric(batch_metadata$latitude[file.number])
  lon <- as.numeric(batch_metadata$longitude[file.number])
  stationName <- strip_file_extension(fileName)
  outputFolders <- outputFolders(baseFolder, stationName)

  qcResult <- load_data_qc(progress, prog_int, file, lat, lon, stationName, base.start, base.end, outputFolders)
  # qcResult now has $errors, $cio, $metadata
  if (qcResult$errors != "") {
    print(qcResult$errors)
    return(qcResult$errors)
  }
  params <- climdexInputParams(wsdi_ud <- batch_metadata$wsdin[file.number],
                                csdi_ud <- batch_metadata$csdin[file.number],
                                rx_ud <- batch_metadata$rxnday[file.number],
                                txtn_ud <- batch_metadata$txtn[file.number],
                                Tb_HDD <- batch_metadata$Tb_HDD[file.number],
                                Tb_CDD <- batch_metadata$Tb_CDD[file.number],
                                Tb_GDD <- batch_metadata$Tb_GDD[file.number],
                                rnnmm_ud <- batch_metadata$rnnmm[file.number],
                                custom_SPEI <- batch_metadata$SPEI[file.number]
                              )

  # title.station <- station_metadata$title.station
  # barplot_flag <- TRUE
  # min_trend <- 10
  # quantiles <- NULL #JMC TODO remove / replace with original intent
  # temp.quantiles <- c(0.05, 0.1, 0.5, 0.9, 0.95)
  # prec.quantiles <- c(0.05, 0.1, 0.5, 0.9, 0.95, 0.99)
  # op.choice <- NULL
  skip <- FALSE

  errorFilePath <- file.path(outputFolders$outputdir, paste0(stationName, ".error.txt"))
  if (file_test("-f", errorFilePath)) {
    file.remove(errorFilePath)
  }

  # # run quality control and create climdex input object
  # catchQC <- tryCatch({
  #             qcResult <- QC.wrapper(progress, prog_int, station_metadata, user.data.ts, file, outputFolders, quantiles)
  #           },
  #           error = function(cond) {
  #             fileConn <- file(errorFilePath)
  #             writeLines(toString(cond$message), fileConn)
  #             close(fileConn)
  #             if (file_test("-f", paste0(file, ".temporary"))) {
  #               file.remove(paste0(file, ".temporary"))
  #             }
  #           })
  # if (skip) { return(NA) }

  # calculate indices
  catchCalc <- tryCatch(index.calc(progress, prog_int, qcResult$metadata, qcResult$cio, outputFolders, params),
                        error = function(cond) {
                          fileConn <- file(errorFilePath)
                          writeLines(toString(cond$message), fileConn)
                          close(fileConn)
                          if (file_test("-f", paste0(file, ".temporary"))) {
                            file.remove(paste0(file, ".temporary"))
                          }
                        })

  if (skip) { return(NA) }

  # RJHD - NH addition for pdf error 2-aug-17
  graphics.off()
  print(paste(file, " done", sep = ""))
}

print_results_to_console <- function(outputFolder) {
  print("", quote = FALSE)
  print("*****************************************************", quote = FALSE)
  print("Processing complete.", quote = FALSE)
  print("", quote = FALSE)
  print("Any errors encountered during processing are listed below by input file. Assess these files carefully and correct any errors.", quote = FALSE)
  print("", quote = FALSE)
  error.files <- suppressWarnings(list.files(path = outputFolder, pattern = paste("*error.txt", sep = "")))
  if (length(error.files) == 0) {
    print("... no errors detected in processing your files. That doesn't mean there aren't any!", quote = FALSE)
  }
  else {
    for (i in 1:length(error.files)) {
      #system(paste("ls ",input.directory,"*error.txt | wc -l",sep=""))) {
      print(error.files[i], quote = FALSE)
      #system(paste("cat ",input.directory,"/",error.files[i],sep=""))
    }
  }
}

# JMC - following non-interactive code runs on shinyapps.io and breaks app
# set up variables and call main function if this is from the command line
# if(!interactive()) {
#   # Enable reading of command line arguments
#   args<-commandArgs(TRUE)

#   # where one or more station files are kept
#   input.directory = toString(args[1])

#   # metadata text file
#   file.list.metadata = toString(args[2])

#   # begin base period
#   base.start = as.numeric(args[3])

#   # end base period
#   base.end = as.numeric(args[4])

#   # establish multiple cores
#   registerDoParallel(cores=as.numeric(args[5]))

#   batch(input.directory,file.list.metadata,base.start,base.end)
# }