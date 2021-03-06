#
# Copyright (C) 2013-2017 University of Amsterdam
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

.quitAnalysis <- function(message) {
  # Function to gracefully exit an analysis when continuing to run is nonsensical.
  # Comparable to stop(message), except this does not raise an exception.
  # Arg message: String with the reason why the analysis has ended.
  
  e <- structure(class = c('expectedError', 'error', 'condition'),
                 list(message=message, call=sys.call(-1)))
  stop(e)
}


.addStackTrace <- function(e) {
  # Adds a stacktrace to the error object when an exception is encountered.
  # Includes up to the latest 10 system calls; the non-informational system calls are omitted.
  # Arg e: error object.

  stack <- ''
  if (! is.null(sys.calls()) && length(sys.calls()) >= 9) {
    
    stack <- sys.calls()  
    stack <- head(stack[7:length(stack)], -2)
    if (length(stack) > 10) {
      stack <- tail(stack, 10)
    }
    
  }
  e$stackTrace <- stack
  signalCondition(e)
}


.generateErrorMessage <- function(type, opening=FALSE, concatenate=NULL, grouping=NULL, ...) {
  # Generic function to create an error message (mostly used by .hasErrors() but it can be called directly).
  # Args:
  #   type: String containing either (1) check type consistent with a message type in commmonmessages.R, or (2) an error message.
  #   opening: Boolean, indicate if there should be a general opening statement (TRUE) or only the specific error message (FALSE).
  #   concatenate: String, include if you want to append the error message to an already existing message.
  #   grouping: String vector indicating the grouping variables. This will add the line 'after grouping on...' to the message.
  #   ...: Each error message can have any number of variables, denoted by {{}}'s. Add these as arg=val pairs.
  #
  # Returns:
  #   String containing the error message.
  
  if (! is.character(type) || length(type) == 0) {
    stop('Non-valid type argument provided')
  }
  
  replaceInMessage <- list('!=' = '≠', '==' = '=')
  args <- c(list(grouping=grouping), list(...))
  
  # Retrieve the error message; spaces indicate that it is already an error message.
  if (grepl(' ', type, fixed=TRUE) == TRUE) {
    message <- type
  } else {
    message <- .messages('error', type)
    if (is.null(message)) {
      stop('Could not find error message for "', type, '" (if you were trying to pass on a message, note that it must be a complete sentence)')
    }
  }
  
  # If a grouping argument is added, the message 'after grouping on {{}}' is automatically included.
  if (! is.null(args[['grouping']])) {
    message <- paste(message, .messages('error', 'grouping'))
  }
  
  # Find all {{string}}'s that needs to be replaced by values.
  toBeReplaced <- regmatches(message, gregexpr("(?<=\\{{)\\S*?(?=\\}})", message, perl=TRUE))[[1]]
  if (base::identical(toBeReplaced, character(0)) == FALSE) { # Were there any {{string}}'s?
    
    if (all(toBeReplaced %in% names(args)) == FALSE) { # Were all replacements provided in the arguments?
      missingReplacements <- toBeReplaced[! toBeReplaced %in% names(args)]
      stop('Missing required replacement(s): "', paste(missingReplacements, collapse=','), '"')
    }
    
    for (i in 1:length(toBeReplaced)) {
      value <- args[[ toBeReplaced[i] ]]
      if (length(value) > 1) { # Some arguments may have multiple values, e.g. amount = c('< 3', '> 5000').
        if (toBeReplaced[i] %in% c('variables', 'grouping')) {
          value <- paste(value, collapse=', ')
        } else {
          value <- paste(value, collapse=' or ')
        }
      }
      message <- gsub(paste0('{{', toBeReplaced[i], '}}'), value, message, fixed=TRUE)
    }
    
  }
  
  # Find all values we do not want in the output, e.g. we do not want to show !=
  for (i in 1:length(replaceInMessage)) {
    if (grepl(names(replaceInMessage)[i], message)) {
      message <- gsub(names(replaceInMessage)[i], replaceInMessage[[i]], message)
    }
  }
  
  # Turn the message in a html list item
  if (! is.null(concatenate) || opening == TRUE) {
    message <- paste0('<li>', message, '</li></ul>')
  }
  
  # See if we should concatenate it with something.
  if (is.character(concatenate) && length(concatenate) == 1) {
    endOfString <- substr(concatenate, nchar(concatenate)-4, nchar(concatenate))
    if (endOfString == '</ul>') {
      concatenate <- substr(concatenate, 1, nchar(concatenate)-5)
    }
    message <- paste0(concatenate, message)
  }
  
  # See if we should add an opening line.
  if (opening == TRUE) {
    openingMsg <- .messages('error', 'opening')
    if (grepl(openingMsg, message, fixed=TRUE) == FALSE) {
      message <- paste0(openingMsg, '<ul>', message)
    }
  }
  
  return(message)
}


.hasErrors <- function(dataset, perform, type, custom=NULL, message='default', exitAnalysisIfErrors=FALSE, ...) {
  # Generic error checking function.
  # Args:
  #   dataset: Normal JASP dataset.
  #   perform: 'run' or 'init'.
  #   type: List/vector of strings containing check types.
  #   message: 'short' or 'default' should only the first failure of a check be reported in footnote style ('short'), or should every check failure be mentioned in multi-line form.
  #   exitAnalysisIfErrors: Boolean, should the function simply return its results (FALSE), or abort the entire analysis when a failing check is encountered (TRUE).
  #   custom: A function that performs some check and returns an error message, or a list containing multiple (named) check functions.
  #   ...: Each check may have required and optional arguments, they are specified in the error check subfunctions.
  #
  # Returns:
  #   FALSE if no errors were found or a named list specifying for each check which variables violated it as well as a general error message.
  
  if (! isTRUE(nrow(dataset) > 0) || perform != 'run' || length(type) == 0) {
    return(FALSE)
  }
  
  if (exitAnalysisIfErrors && message == 'short') {
    message <- 'default'
  }
  
  # Error checks definition.
  checks <- list()
  checks[['infinity']] <- list(callback=.checkInfinity, addGroupingMsg=FALSE)
  checks[['factorLevels']] <- list(callback=.checkFactorLevels)
  checks[['variance']] <- list(callback=.checkVariance, addGroupingMsg=TRUE)
  checks[['observations']] <- list(callback=.checkObservations, addGroupingMsg=TRUE)
  
  args <- c(list(dataset=dataset), list(...))
  errors <- list(message=NULL)
  
  # Add info about the custom check functions to the type and checks objects.
  if (length(custom) > 0) {
    if (is.function(custom)) {
      checks[['_custom']] <- list(callback=custom, isCustom=TRUE, hasNamespace=FALSE)
      type <- c(type, '_custom')
    } else if (is.list(custom)) {
      
      if (is.null(names(custom))) {
        names(custom) <- paste0('_custom', seq(length(custom)))
        namespace <- FALSE
      } else {
        namespace <- TRUE
      }
      
      for (i in 1:length(custom)) {
        if (is.function(custom[[i]])) {
          checks[[ names(custom)[i] ]] <- list(callback=custom[[i]], isCustom=TRUE, hasNamespace=namespace)
          type <- c(type, names(custom)[i])
        }
      }
      
    }
  }
  
  for (i in 1:length(type)) {
    
    check <- checks[[ type[[i]] ]]
    if (is.null(check)) {
      stop('Unknown check type provided: "', type[[i]], '"')
    }
    
    isCustom <- ! is.null(check[['isCustom']]) # Is it an analysis-specific check?
    hasNamespace <- ! isCustom || check[['hasNamespace']] == TRUE # Is it a named check?
    
    # Check the arguments provided/required for this specific check.
    funcArgs <- NULL
    if (hasNamespace) {
      funcArgs <- base::formals(check[['callback']])
      funcArgs['...'] <- NULL
      if (length(funcArgs) > 0) {
        # Attach the check specific prefix, except for the dataset arg.
        names(funcArgs)[names(funcArgs) != 'dataset'] <- paste0(type[[i]], '.', names(funcArgs)[names(funcArgs) != 'dataset'])
        
        # Fill in the 'all.*' arguments for this check
        # TODO when R version 3.3 is installed we can use: argsAllPrefix <- args[startsWith(names(args), 'all.')]
        argsAllPrefix <- args[substring(names(args), 1, 4) == 'all.']
        if (length(argsAllPrefix) > 0) {
          for (a in names(argsAllPrefix)) {
            funcArg <- gsub('all', type[[i]], a, fixed=TRUE)
            if (funcArg %in% names(funcArgs)) {
              args[[funcArg]] <- args[[a]]
            }
          }
        }
        
        # See if this check expects target variables and if they were provided, if not add all variables.
        if (paste0(type[[i]], '.target') %in% names(funcArgs) && ! paste0(type[[i]], '.target') %in% names(args)) {
          args[[ paste0(type[[i]], '.target') ]] <- .unv(names(dataset))
        } 
        
        # Obtain an overview of required and optional check arguments.
        optArgs <- list()
        reqArgs <- list()
        for (a in 1:length(funcArgs)) {
          if (is.symbol(funcArgs[[a]])) { # Required args' value is symbol.
            reqArgs <- c(reqArgs, funcArgs[a])
          } else {
            optArgs <- c(optArgs, funcArgs[a])
          }
        }
        
        if (length(reqArgs) > 0 && all(names(reqArgs) %in% names(args)) == FALSE) {
          missingArgs <- reqArgs[! names(reqArgs) %in% names(args)]
          stop('Missing required argument(s): "', paste(names(missingArgs), collapse=','), '"')
        }
        
        if (length(optArgs) > 0 && all(names(optArgs) %in% names(args)) == FALSE) {
          args <- c(args, optArgs[! names(optArgs) %in% names(args)])
        }
      }
      
    }
    
    # Perform the actual error check.
    if (hasNamespace && length(funcArgs) > 0) {
      callingArgs <- args[names(funcArgs)]
      names(callingArgs) <- gsub(paste0(type[[i]], '.'), '', names(callingArgs), fixed=TRUE)
      checkResult <- base::do.call(check[['callback']], callingArgs)
    } else {
      checkResult <- check[['callback']]()
    }
    
    # If we don't have an error we can go to the next check.
    if ((! isCustom && checkResult[['error']] != TRUE) || (isCustom && (! is.character(checkResult) || checkResult == ''))) {
      next
    }
    
    # Create the error message.
    if (! (message == 'short' && ! is.null(errors[['message']]))) {
      opening <- FALSE
      if (is.null(errors[['message']]) && message != 'short') {
        opening <- TRUE
      }
      
      varsToAdd <- NULL
      if (! isCustom) {
        varsToAdd <- checkResult[['errorVars']]
      }
      
      grouping <- NULL
      if (! is.null(check[['addGroupingMsg']]) && check[['addGroupingMsg']] == TRUE && 
          ! is.null(args[[ paste0(type[[i]], '.grouping') ]]) ) {
        grouping <- args[[ paste0(type[[i]], '.grouping') ]]
      }
      
      msgType <- type[[i]]
      if (isCustom) {
        msgType <- checkResult
      }
      
      errors[['message']] <- base::do.call(.generateErrorMessage, c(list(type=msgType, 
        opening=opening, concatenate=errors[['message']], variables=varsToAdd, grouping=grouping), 
        args))
    }
    
    if (! hasNamespace) {
      next  # We won't add info of the error to the list if we don't have a name.
    }
    
    # Add the error (with any offending variables, or TRUE if there were no variables) to the list.
    if (is.list(checkResult) && ! is.null(checkResult[['errorVars']])) {
      errors[[ type[[i]] ]] <- checkResult[['errorVars']]
    } else {
      errors[[ type[[i]] ]] <- TRUE
    }
    
  } # End for-loop.
  
  if (is.null(errors[['message']]))  {
    return(FALSE)
  } 
  
  if (exitAnalysisIfErrors == TRUE) {
    .quitAnalysis(errors[['message']])
  }
  
  return(errors) 
}


.applyOnGroups <- function(func, dataset, target, grouping, levels=NULL) {
  # Convenience function to apply a check on a specific level of the dependent, or on all subgroups.
  # Args:
  #   func: Function to perform on the subgroup(s).
  #   dataset: JASP dataset.
  #   target: Single string with the dependent variable.
  #   grouping: String vector indicating the grouping variables.
  #   levels: Vector indicating the level of each of the grouping variables.
  #
  # Returns:
  #   Result of the func in vector form when no levels were supplied, otherwise as a single value.

  
  if (length(levels) > 0) {
    
    if (length(grouping) != length(levels)) {
      stop('Each grouping variable must have a level specified')
    }
    
    # The levels vector may be a 'mix' of numeric and characters, we need to add additional quotation marks around characters.
    if (is.character(levels)) {
      levels <- vapply(levels, function(x) {
        if (suppressWarnings(is.na(as.numeric(x)))) {
          paste0("\"", x, "\"")
        } else {
          x
        }
      }, character(1))
    }
    
    expr <- paste(.v(grouping), levels, sep='==', collapse='&')
    dataset <- subset(dataset, eval(parse(text=expr)))
    result <- func(dataset[[.v(target)]])
    
  } else {
    
    result <- plyr::ddply(dataset, .v(grouping), function(data, target) func(data[[.v(target)]]), target)
    result <- result[[ncol(result)]] # The last column holds the func results.
    
  }
  
  return(result)
}


.checkInfinity <- function(dataset, target, grouping=NULL, groupingLevel=NULL) {
  # Check for infinity in the dataset. 
  # Args:
  #   dataset: JASP dataset.
  #   target: String vector indicating the target variables.
  #   grouping: String vector indicating the grouping variables.
  #   groupingLevel: Vector indicating the level of each of the grouping variables.
  
  result <- list(error=FALSE, errorVars=NULL)
  
  findInf <- function(x) {
    return(any(is.infinite(x)))
  }
  
  for (v in target) {
    
    if (is.factor(dataset[[.v(v)]])) { # Coerce factor to numeric.
      dataset[[.v(v)]] <- as.numeric(as.character(dataset[[.v(v)]]))
    } 
    
    if (length(grouping) > 0 && length(groupingLevel) > 0) { 
      hasInf <- .applyOnGroups(findInf, dataset, v, grouping, groupingLevel)
    } else { # Makes no sense to check all subgroups for infinity rather than the entire variable at once.
      hasInf <- findInf(dataset[[.v(v)]])
    }
    
    if (hasInf) {
      result$error <- TRUE
      result$errorVars <- c(result$errorVars, v)
    }
    
  }
  return(result)
}


.checkFactorLevels <- function(dataset, target, amount) {
  # Check if there are the required amount of levels in factors.
  # Args:
  #   dataset: JASP dataset.
  #   target: String vector indicating the target variables.
  #   amount: String vector indicating the amount to check for (e.g. '< 2', or '!= 2').
  
  result <- list(error=FALSE, errorVars=NULL)

  for (v in target) {
    
    levelsOfVar <- length(unique(na.omit(dataset[[.v(v)]])))
    for (checkAmount in amount) {
      expr <- paste(levelsOfVar, checkAmount)
      if (eval(parse(text=expr))) {
        result$error <- TRUE
        result$errorVars <- c(result$errorVars, v)
        break
      }
    }
    
  }
  return(result)
}


.checkVariance <- function(dataset, target, equalTo=0, grouping=NULL, groupingLevel=NULL) {
  # Check for a certain variance in the dataset. 
  # Args:
  #   dataset: JASP dataset.
  #   target: String vector indicating the target variables.
  #   equalTo: Single numeric.
  #   grouping: String vector indicating the grouping variables.
  #   groupingLevel: Vector indicating the level of each of the grouping variables.
  
  result <- list(error=FALSE, errorVars=NULL)
  
  getVariance <- function(x) {
    validValues <- x[is.finite(x)]
    variance <- -1 # Prevents the function from returning NA's
    if (length(validValues) > 1) {
      variance <- stats::var(validValues)
    }
    return(variance)
  }
  
  for (v in target) {
    
    if (length(grouping) > 0) {
      variance <- .applyOnGroups(getVariance, dataset, v, grouping, groupingLevel)
    } else {
      variance <- getVariance(dataset[[.v(v)]])
    }
    
    if (any(variance == equalTo)) {
      result$error <- TRUE
      result$errorVars <- c(result$errorVars, v)
    }
    
  }
  return(result)
}


.checkObservations <- function(dataset, target, amount, grouping=NULL, groupingLevel=NULL) {
  # Check the number of observations in the dependent(s).
  # Args:
  #   dataset: JASP dataset.
  #   target: String vector indicating the target variables.
  #   amount: String vector indicating the amount to check for (e.g. '< 2', or '> 4000').
  #   grouping: String vector indicating the grouping variables.
  #   groupingLevel: Vector indicating the level of each of the grouping variables.
  
  result <- list(error=FALSE, errorVars=NULL)
  
  getObservations <- function(x) {
    return(length(na.omit(x)))
  }
  
  for (v in target) {
    
    if (length(grouping) > 0) {
      obs <- .applyOnGroups(getObservations, dataset, v, grouping, groupingLevel)
    } else {
      obs <- getObservations(dataset[[.v(v)]])
    }
    
    for (checkAmount in amount) {
      expr <- paste(obs, checkAmount)
      if (any(sapply(expr, function(x) eval(parse(text=x))))) { # See if any of the expressions is true.
        result$error <- TRUE
        result$errorVars <- c(result$errorVars, v)
        break
      }
    }
    
  }
  return(result)
}