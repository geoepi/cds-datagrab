safe_date_sequence <- function(from,to) { from<-as.Date(from); to<-as.Date(to); if(length(from)!=1L||length(to)!=1L)stop("`from` and `to` must each be scalar dates.",call.=FALSE); if(is.na(from)||is.na(to))stop("`from` and `to` must be valid dates.",call.=FALSE); if(from>to)return(as.Date(character())); seq.Date(from=from,to=to,by="day") }
canonical_iso_dates <- function(x, field = "date") {
  if (is.null(x) || length(x) == 0L) return(character())
  while (is.list(x) && length(x) == 1L) x <- x[[1L]]
  if (is.list(x)) x <- unlist(x, recursive = TRUE, use.names = FALSE)
  if (inherits(x, "Date")) {
    if (anyNA(x)) stop(field, " contains missing or invalid dates", call. = FALSE)
    return(unname(format(x, "%Y-%m-%d")))
  }
  if (inherits(x, c("POSIXct", "POSIXlt"))) {
    parsed <- as.Date(x, tz = "UTC")
    if (anyNA(parsed)) stop(field, " contains missing or invalid dates", call. = FALSE)
    return(unname(format(parsed, "%Y-%m-%d")))
  }
  if (is.factor(x)) x <- as.character(x)
  if (!is.character(x)) stop(field, " must contain Date values or ISO YYYY-MM-DD strings; received class: ", paste(class(x), collapse = "/"), call. = FALSE)
  parsed <- as.Date(x, format = "%Y-%m-%d")
  invalid <- is.na(parsed) | format(parsed, "%Y-%m-%d") != x
  if (any(invalid)) stop(field, " contains invalid ISO dates: ", paste(unique(x[invalid]), collapse = ", "), call. = FALSE)
  unname(format(parsed, "%Y-%m-%d"))
}
normalize_date_vector <- function(x,argument=deparse(substitute(x))) { iso <- canonical_iso_dates(x, argument); as.Date(iso, format = "%Y-%m-%d") }
expected_daily_dates <- function(start_date,end_date) safe_date_sequence(start_date,end_date)
find_missing_dates <- function(observed_dates,start_date,end_date) { candidate<-safe_date_sequence(start_date,end_date); sort(unique(as.Date(setdiff(candidate,sort(unique(as.Date(observed_dates))))))) }
compress_dates_to_intervals <- function(dates) { d <- sort(unique(as.Date(dates))); if(!length(d)) return(data.frame(start=as.Date(character()), end=as.Date(character()))); z <- c(TRUE, diff(d)!=1); g <- cumsum(z); data.frame(start=as.Date(tapply(d,g,min)), end=as.Date(tapply(d,g,max))) }
split_dates_by_year_month <- function(dates) { d <- sort(unique(as.Date(dates))); if(!length(d)) return(data.frame(year=character(),month=character(),date=as.Date(character()))); data.frame(year=format(d,"%Y"), month=format(d,"%m"), date=d) }
plan_observed_update <- function(daily_inventory, initial_start_date, observed_end, overlap_days=14) {
  start<-as.Date(initial_start_date); end<-as.Date(observed_end); candidate<-safe_date_sequence(start,end); obs<-sort(unique(as.Date(daily_inventory$date[daily_inventory$valid & !daily_inventory$estimated]))); obs<-obs[!is.na(obs)]; est<-as.Date(daily_inventory$date[daily_inventory$valid & daily_inventory$estimated]); invalid_dates<-if("filename_valid"%in%names(daily_inventory))sort(unique(as.Date(daily_inventory$date[daily_inventory$filename_valid & !daily_inventory$observed_valid & !daily_inventory$estimated])))else as.Date(character()); missing<-sort(unique(c(setdiff(candidate,obs),invalid_dates))); overlap<-if(length(obs)&&overlap_days>0L) safe_date_sequence(max(min(obs),max(obs)-as.integer(overlap_days)+1L),min(max(obs),end)) else as.Date(character()); d<-sort(unique(c(missing,overlap))); reason<-if(!length(d))character()else ifelse(d%in%invalid_dates,"invalid_existing_output",ifelse(d%in%setdiff(candidate,obs),"internal_gap",ifelse(d%in%overlap,"overlap","new"))); out<-if(!length(d))data.frame(date=as.Date(character()),reason=character(),represented_only_by_estimate=logical())else data.frame(date=d,reason=reason,represented_only_by_estimate=d%in%est); attr(out,"status")<-if(length(d))"planned"else"success_noop";attr(out,"reason")<-if(length(d))"dates_required"else"no_missing_dates";out
}
