data {
  int<lower=1> N; // number of obs (historic only)
  real beta_mu;   // priors on climate resistance (via TCR)        
  real<lower=0> beta_sigma; // priors on climate resistance (via TCR)
  vector[N] gmst;
  vector[N] trf;    
  vector[N] volc;      
  vector[N] amo;      
  vector[N] soi;      
}
parameters {
  real<lower=0> sigma;
  real alpha;
  real beta;
  real gamma;
  real delta;
  real eta;
  real<lower=-1,upper=1> phi; // AR(1) param
}
transformed parameters {
  // Only estimating historic data (up to N periods)
  vector[N] mu;
  vector[N] epsilon;
  real<lower=0> sigma_cor;
  // First period
  mu[1] = alpha + beta*trf[1] + gamma*volc[1] + delta*soi[1] + eta*amo[1];
  epsilon[1] = gmst[1] - mu[1]; // observed minus predicted
  // Subsequent periods
  for(t in 2:N) {
    mu[t] = alpha + beta*trf[t] + gamma*volc[t] + delta*soi[t] + eta*amo[t] + phi*epsilon[t-1];
    epsilon[t] = gmst[t] - mu[t]; // observed minus predicted
  }
  // Full AR(1) error
  sigma_cor = sqrt(sigma*sigma * (1-phi*phi)); // Var = sigma2 * (1-rho^2)
}
model {
  phi ~ normal(0,1);
  gmst ~ normal(mu, sigma_cor);
  sigma ~ cauchy(0,5);
  alpha ~ normal(0, 1);
  beta ~ normal(beta_mu, beta_sigma);
  gamma ~ normal(0, 1.92);
  delta ~ normal(0, 0.54);
  eta ~ normal(0, 3.37);
}