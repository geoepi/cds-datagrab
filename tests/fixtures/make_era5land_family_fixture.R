make_era5land_family_fixture <- function(path) {
  if (!requireNamespace("ncdf4", quietly=TRUE)) stop("ncdf4 is required")
  lon <- ncdf4::ncdim_def("longitude","degrees_east",c(-126.5,-126.0)); lat <- ncdf4::ncdim_def("latitude","degrees_north",c(42.5,43.0)); time <- ncdf4::ncdim_def("time","hours since 2026-02-01 00:00:00",c(0,24,48),calendar="standard")
  specs <- list(t2m=list(units="K",base=273.15),stl1=list(units="K",base=275),stl2=list(units="K",base=277),swvl1=list(units="m3 m-3",base=.3),swvl2=list(units="m3 m-3",base=.4),sp=list(units="Pa",base=100000),lai_hv=list(units="m2 m-2",base=3),lai_lv=list(units="m2 m-2",base=1))
  vars <- lapply(names(specs), function(n) ncdf4::ncvar_def(n,specs[[n]]$units,list(lon,lat,time),-9999,prec="double")); names(vars) <- names(specs); nc <- ncdf4::nc_create(path,vars,force_v4=TRUE); on.exit(ncdf4::nc_close(nc),add=TRUE)
  for (n in names(vars)) { z <- array(specs[[n]]$base,dim=c(2,2,3)); z[1,1,1] <- -9999; z[2,2,] <- z[2,2,] + seq(0,.2,length.out=3); ncdf4::ncvar_put(nc,vars[[n]],z) }
  ncdf4::ncatt_put(nc,"t2m","scale_factor",1); ncdf4::ncatt_put(nc,"sp","add_offset",0); path
}
