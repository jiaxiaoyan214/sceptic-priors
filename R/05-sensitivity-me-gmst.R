modrun = 'me-gmst'
ptime = proc.time()

# Libraries ---------------------------------------------------------------

library(cmdstanr)
library(posterior)
library(data.table)
library(fst)
library(future.apply)
library(progressr)
library(here)

## Progress bar options and output
options(progressr.enable = TRUE) ## For batch mode
handlers(
	handler_progress(
		format   = ":spin :current/:total (:message) [:bar] :percent in :elapsed ETA: :eta",
		width    = 60,
		complete = "+"
	)
)

# Global variables and functions ------------------------------------------

## Stan model (will compile first time it is run)
mod = cmdstan_model(here('stan/mod-me.stan'))

set.seed(123)
n_chains = 4
chain_length = 1000
rf2x = rnorm(n_chains * chain_length, mean = 3.71, sd = 0.1855)

center_pre2005 = function(d) {
	d = as.data.table(d)
	d05 = d[year<=2005, .SD, .SDcols = is.numeric][, !'year']
	cols05 = colnames(d05)
	colsother = setdiff(colnames(d), cols05)
	dnums = d[, ..cols05]
	dnums = sweep(dnums, 2, apply(d05, 2, mean, na.rm = TRUE))
	ret = cbind(d[, ..colsother], dnums)
}


# Load data ---------------------------------------------------------------

## Load climate data. Then subset and add "omega" column (i.e. measurement
## error std deviation) for HadCRUT4 series. Note that the cw series (i.e Cowtan
## & Way 2014) already has an omega equivalent in the data, but in the paper I
## only focus on HadCRUT4 for consistency's sake.
## 
climate = fread(here("data/climate.csv"))[
	rcp=='rcp60' & year <= 2005, 
	.(year, had, had_025, had_975, trf, volc_mean, soi_mean, amo_mean)]
climate[, had_omega := (had_975 - had)/2] ## 95% bound, i.e. 2*sigma.

## Load priors data frame
priors_df = fread(here("data/priors.csv"))


# Set up loop function ----------------------------------------------------

plan(multisession, workers = floor(availableCores()/n_chains))

priors_loop = function() {
	pb = progressor(along = 1:nrow(priors_df))
	future_lapply(
		1:nrow(priors_df),
		function(j) {
			
			# * Priors ----------------------------------------------------------      
			
			beta_mu = priors_df$mu[j]
			beta_sigma = round(priors_df$sigma[j], 3)
			prior_type = priors_df$prior_type[j]
			convic_type = priors_df$convic_type[j]
			prior_convic = paste0(prior_type, convic_type)
			
			## Progress bar
			pb(sprintf("Prior = %s", prior_convic), class = "sticky")
			
			## adjust subjective TCR priors to climate resistance scale 
			if (j!=1) {
				beta_mu = beta_mu/3.71
				beta_sigma = beta_sigma/3.71
			}
			
			
			clim_df = climate[, .(year, had, had_omega, trf, volc_mean, soi_mean, amo_mean)]
			
			## Center the vars according to pre 2005 values
			clim_df = center_pre2005(clim_df)
			
			
			# ** Specify data list and params -----------------------------
			
			N = nrow(clim_df)
			
			## Standard deviation for weakly informative priors. Here I follow
			## the advice of the Stan core team, using 2.5 * sd(y) / sd(x). The
			## prior means of the centered data are ofc zero.
			wi_sigma = function(gmst_var = 'had') {
				sd_cols = setdiff(names(clim_df), c('year', gmst_var, 'had_omega')) ## NB: Manual exclude for this run
				sd_cols = setdiff(sd_cols, names(which(!sapply(clim_df, is.numeric))))
				clim_df[year<=2005 , 
								lapply(.SD, function(x) round(2.5*sd(get(gmst_var))/sd(x), 2)), 
								.SDcols = sd_cols]
			}
			prior_sigmas = wi_sigma()
			
			data_list = 
				list(
					'N' = N, 
					'gmst' = clim_df$had, 'gmst_omega' = clim_df$had_omega,
					'trf' = clim_df$trf, 
					'volc' = clim_df$volc_mean, 'soi' = clim_df$soi_mean, 
					'amo' = clim_df$amo_mean,
					'beta_mu' = beta_mu, 'beta_sigma' = beta_sigma,
					'gamma_sigma' = prior_sigmas$volc_mean,
					'delta_sigma' = prior_sigmas$soi_mean,
					'eta_sigma' = prior_sigmas$amo_mean
				)
			
			
			# ** Fit the CmdStanR model -----------------------------------
			
			## Model fit
			fit = 
				mod$sample(
					data = data_list,
					seed = 123,
					chains = n_chains,
					parallel_chains = n_chains,
					iter_sampling = chain_length,
					refresh = 0,
					show_messages = FALSE
				)
			
			## Params of interest
			params = c("alpha", "beta", "gamma", "delta", "eta", "phi")
			
			
			# ** Posterior draws ------------------------------------------
			
			## TCR
			beta_draws = as.matrix(fit$draws("beta"))[, 1]
			tcr = data.table(tcr = rf2x * beta_draws, prior = prior_convic)
			
			## Summary table
			params_tab = 
				rbind(
					data.table(fit$summary(params, "mean", ~quantile(.x, probs = c(0.025, 0.975), na.rm = TRUE))),
					tcr[, .('tcr', mean(tcr), quantile(tcr, .025, na.rm = TRUE), quantile(tcr, .975, na.rm = TRUE))],
					use.names = FALSE
				)
			setnames(params_tab, 
							 old = c('variable','2.5%', '97.5%'), 
							 new = c('param', 'q025', 'q975'))
			params_tab$prior = prior_convic
			# num_cols = c('mean', 'q025', 'q975')
			# params_tab[ , (num_cols) := lapply(.SD, function(x) sprintf('%.3f', x)), .SDcols = num_cols]
			
			
			return(list(params_tab = params_tab, tcr = tcr))
		},
		future.seed = 123L
	)
}


# Run Stan models (with progress bar) -------------------------------------

system.time(with_progress({res = priors_loop()}))

## Recombine the sub-elements of the list based on their common indexes
res =
	do.call(function(...) mapply(rbind, ..., SIMPLIFY = FALSE), args = res)

res$tcr$run = modrun
res$params_tab$run = modrun

# Export results ----------------------------------------------------------

res_dir = 'results/sensitivity'

write_fst(res$tcr, here(res_dir, paste0('tcr-', modrun,'.fst')))
fwrite(res$params_tab, here(res_dir, paste0('params-', modrun,'.csv')))


## Performance
ptime = proc.time() - ptime
mem_gb = as.numeric(system(
	"awk '/MemTotal/ { print $2/1024/1024 }' /proc/meminfo", 	
	intern=TRUE))
perf = data.table(run = modrun, sec = sprintf('%.3f', ptime[[3]]), 
									cores = future::availableCores(),
									mem_gb = round(mem_gb),	os = sessionInfo()$running, 
									arch = sessionInfo()$platform)
fwrite(perf, here('performance', paste0('perf-', modrun, '.csv')))