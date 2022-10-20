library(tidyverse)
library(brms)
library(rstan)
library(tidybayes)
library(janitor)
library(sizeSpectra)
library(ggridges)

# 1) load data ----------------------------------------
macro_fish_mat <- readRDS("data/macro_fish_mat.rds") 

mle_mat <- read_csv("C:/Users/Jeff.Wesner/OneDrive - The University of South Dakota/USD/Github Projects/neon_size_spectra/data/derived_data/mle_mat.csv") %>% 
  select(-ID) %>% 
  left_join(macro_fish_mat %>% distinct(site_id, mat_s))

# macro_fish_mat = macro_fish_mat %>% left_join(mle_mat) %>% 
#   group_by(ID) %>% 
#   mutate(xmin = min(dw),
#          xmax = max(dw),
#          x = dw,
#          counts = no_m2) %>% 
#   ungroup() %>%
#   mutate(site_no = as.numeric(factor(site_id)),
#          mat_s = (mat_site - mean(mat_site))/sd(mat_site))

# 2) fit model ------------------------------------------------------------
# prior predictive
N = 1000
prior_sim <- tibble(beta = rnorm(N, 0, 0.1),
                    sigma_year = abs(rnorm(N, 0, 0.1)),
                    sigma_site = abs(rnorm(N, 0, 0.1)),
                    alpha_year_raw = rnorm(N, 0, 5),
                    alpha_site_raw = rnorm(N, 0, 5),
                    a = rnorm(N, -1.5, 0.2),
                    .draw = 1:N) %>% 
  mutate(intercept = a + sigma_year*alpha_year_raw + sigma_site*alpha_site_raw) %>% 
  expand_grid(mat_s = seq(-2, 2, length.out = 20)) %>% 
  mutate(y_pred = intercept + beta*mat_s)

prior_sim %>% 
  ggplot(aes(x = mat_s, y = y_pred, group = .draw)) + 
  geom_line(alpha = 0.2)


# fit full model
macro_fish_mat = macro_fish_dw %>% 
  group_by(ID) %>% 
  mutate(xmin = min(dw),
         xmax = max(dw)) %>% 
  distinct() %>% 
  ungroup() %>% 
  # sample_n(size = 18000) %>%
  # slice(1:50) %>%
  filter(site_id %in% c("ARIK", "BIGC", "BLDE", "CUPE")) %>%
  {.}

site_id = macro_fish_mat %>% ungroup() %>% distinct(site_id, mat_s)
site_id_site = tibble(site_id = site_id$site_id, 
                      site = as.integer(as.factor(unique(macro_fish_mat$site_id)))) %>% 
  left_join(site_id)


# get fitted model
mod_spectra = readRDS(file = "models/mod_spectra.rds")

sim_regressions <- mod_spectra %>% 
  as_draws_df() %>% 
  pivot_longer(cols = contains("raw_site")) %>% 
  mutate(site = as.integer(parse_number(name)),
         model = "bayes") %>% 
  select(name, value, site, sigma_site, a, beta, .draw) %>% 
  left_join(macro_fish_mat %>% ungroup %>% distinct(site_id, site_id_int, mat_s) %>% rename(site = site_id_int)) %>%
  mutate(offset = sigma_site*value) %>%
  mutate(a_site = a + beta*mat_s) %>% 
  group_by(name, site_id, mat_s) %>% 
  median_qi(a_site) 

sim_regressions %>% 
  ggplot(aes(x = mat_s, y = a_site)) + 
  geom_line() + 
  geom_ribbon(aes(ymin = .lower, ymax = .upper), alpha = 0.2) +
  theme_ggdist() + 
  geom_point(data = mle_mat %>% distinct(b, mat_s), aes(y = b)) + 
  labs(y = "b exponent",
       x = "Standardized Temperature",
       caption = "Dots are the old b estimates from the SizeSpectra package. Regression lines are from the new Stan model")



sim_site_means <- mod_spectra %>% 
  as_draws_df() %>% 
  pivot_longer(cols = contains("raw_site")) %>% 
  mutate(offset = sigma_site*value) %>%
  mutate(a_site = a + offset) %>% 
  mutate(site = as.integer(parse_number(name)),
         model = "bayes") %>% 
  left_join(macro_fish_mat %>% ungroup %>% distinct(site_id, site_id_int, mat_s) %>% rename(site = site_id_int))

sim_site_means %>% 
  ggplot(aes(x = reorder(site_id, a_site), y = a_site)) +
  geom_violin(aes(group = mat_s)) + 
  geom_point(data = mle_mat %>% ungroup %>% distinct(site_id, b), aes(x = reorder(site_id, b), y = b),
             shape = 21, size = 1) + 
  coord_flip() + 
  theme_ggdist() + 
  labs(y = "b exponent",
       x = "NEON site",
       caption = "Dots are the old b estimates from the SizeSpectra package. Posteriors are from the new Stan model")



# Plot --------------------------------------------------------------------

### Simulate regression lines

# 1) To make regression lines, simulate sequence between xmin and xmax for each sample,
# then join raw data identifiers and posteriors estimates of b (a_site, upper, lower, etc)...

# function to generate log sequence (other wise all of the numbers are too large for x to plot correctly)
# https://stackoverflow.com/questions/23901907/create-a-log-sequence-across-multiple-orders-of-magnitude
# logarithmic spaced sequence

lseq <- function(from=xmin, to=xmax, length.out=7) {
  exp(seq(log(from), log(to), length.out = length.out))
}

sim_grid <- macro_fish_mat %>%
  mutate(group = ID) %>% 
  ungroup() %>% 
  distinct(group, xmin, xmax) %>% 
  pivot_longer(cols = c(xmin, xmax)) %>%
  arrange(group, value) %>% 
  group_by(group) %>% 
  complete(value = lseq(min(value), max(value), length.out = 800)) %>% 
  select(-name) %>% 
  rename(x = value) %>% 
  left_join(macro_fish_mat %>% mutate(group = ID) %>% distinct(group, ID, site_id, year, xmin, xmax)) %>%  
  left_join(sim_regressions %>% 
              select(site_id, a_site, .lower, .upper)) 


# 2) ...then simulate prob x >= x for each x. y_plb estimates come from line 155 here: https://github.com/andrew-edwards/fitting-size-spectra/blob/master/code/PLBfunctions.r


line_sim <- sim_grid %>% 
  mutate(y_plb_med = 1 - (x^(a_site+1) - xmin^(a_site+1))/(xmax^(a_site+1) - xmin^(a_site+1)), # simulate prob x>=x
         y_plb_lower = 1 - (x^(.lower+1) - xmin^(.lower+1))/(xmax^(.lower+1) - xmin^(.lower+1)),
         y_plb_upper = 1 - (x^(.upper+1) - xmin^(.upper+1))/(xmax^(.upper+1) - xmin^(.upper+1))) %>%
  filter(y_plb_med > 0) %>% 
  filter(y_plb_lower > 0) %>% 
  filter(y_plb_upper > 0) %>% 
  arrange(group, x) %>%
  mutate(x = round(x, 5)) %>% 
  distinct(group, x, .keep_all = T)

### Simulate raw data (i.e., data that "would" have been collected after accounting for no_m2)

# 3) To simulate raw data, get counts of organisms and cumulative counts...
dat_bayes_counts = macro_fish_mat %>% 
  mutate(group = ID) %>% 
  select(dw, no_m2, group) %>% ungroup() %>% 
  group_by(dw, group) %>% 
  summarize(Count = sum(no_m2)) %>% 
  arrange(group, desc(dw)) %>% 
  group_by(group) %>% 
  mutate(cumSum = cumsum(Count),
         cumProp = cumSum / sum(Count),
         length = ceiling(sum(Count))) 

# 4) then generate sequence of values to simulate over
dat_bayes_sim <- dat_bayes_counts %>% 
  dplyr::group_by(group, length) %>% 
  dplyr::summarize(min_cumProp = min(cumProp)) %>% 
  dplyr::group_by(group) %>% 
  dplyr::do(dplyr::tibble(cumPropsim = seq(.$min_cumProp, 1, length = .$length/10))) # dividing by something reduces file size by limiting iterations, but check for accuracy

# 5) then simulate cumulative proportion data to plot against MLE estimates by group
# make lists first
dat_bayes_simlist <- dat_bayes_sim %>% dplyr::group_by(group) %>% dplyr::group_split() 
dat_bayes_countslist <- dat_bayes_counts %>% dplyr::group_by(group) %>% dplyr::group_split() 
bayes_sim = list() # empty list to population

# simulate data with for loop
for(i in 1:length(dat_bayes_simlist)){
  bayes_sim[[i]] = dat_bayes_simlist[[i]] %>% dplyr::as_tibble() %>% 
    dplyr::mutate(dw = dat_bayes_countslist[[i]][findInterval(dat_bayes_simlist[[i]]$cumPropsim,
                                                                     dat_bayes_countslist[[i]]$cumProp), ]$dw)
}

# 6) Create data frame with "raw" data to plot
bayes_sim_tibble <- dplyr::bind_rows(bayes_sim) # dots to plot...very large file


# 7) Make plot

line_sim %>%
  filter(site_id == "ARIK") %>% 
  ggplot(aes(x = x, y = y_plb_med)) + 
  geom_line() +
  geom_ribbon(aes(ymin = y_plb_lower, ymax = y_plb_upper), alpha = 0.2) +
  scale_x_log10() +
  scale_y_log10() +
  facet_wrap(~group, scales = "free") +
  geom_point(data = bayes_sim_tibble %>%  
               filter(group == 1:9)  , aes(x = dw, y = cumPropsim)) +
  NULL




# Posterior Predictive ----------------------------------------------------

# 1) get posterior mean and sd for chosen parameters
post_mean_sd_parameter = as_draws_df(mod_spectra) %>% as_tibble() %>% clean_names() %>% 
  select(a) %>%  # change for different parameters/groups
  summarize(b = mean(a),
            sd = sd(a)) %>% 
  expand_grid(site_id = macro_fish_mat %>% ungroup %>% distinct(site_id) %>% pull())

# 2) simulate y_pred
sim_ypred <- macro_fish_mat %>% 
  left_join(post_mean_sd_parameter) %>%       # add posterior mean/sd/upper/lower
  expand_grid(sim = 1:10) %>%                 # number of data sets to simulate
  mutate(u = runif(nrow(.))) %>%              # uniform sample for simulation
  mutate(y_pred = (u*xmax^(b+1) +  (1-u) * xmin^(b+1) ) ^ (1/(b+1))) %>% # simulate y_pred (via Edwards github for rPLB) - confirmed in code/rplb_by_hand.R
  group_by(ID) %>% 
  mutate(rank = rank(y_pred)) %>%             # rank within groups
  mutate(group = paste(site_id, year, sep = "_")) %>%  # clean up to combine with raw data
  mutate(y_pred = round(y_pred, 5)) %>%
  select(ID,site_id, y_pred, sim) %>%
  group_by(ID, y_pred, site_id, sim) %>%
  count(y_pred) %>%
  mutate(model = "y_pred") %>% 
  rename(dw = y_pred,
         no_m2 = n)

# 3) get counts of organisms and cumulative counts...
sim_bayes_counts = sim_ypred %>% 
  mutate(group = paste(ID, sim, sep = "_")) %>% 
  select(dw, no_m2, group) %>% ungroup() %>% 
  group_by(dw, group) %>% 
  summarize(Count = sum(no_m2)) %>% 
  arrange(group, desc(dw)) %>% 
  group_by(group) %>% 
  mutate(cumSum = cumsum(Count),
         cumProp = cumSum / sum(Count),
         length = ceiling(sum(Count))) 

# 4) then generate sequence of values to simulate over
sim_bayes_sim <- sim_bayes_counts %>% 
  dplyr::group_by(group, length) %>% 
  dplyr::summarize(min_cumProp = min(cumProp)) %>% 
  dplyr::group_by(group) %>% 
  dplyr::do(dplyr::tibble(cumPropsim = seq(.$min_cumProp, 1, length = .$length/10))) # dividing by something reduces file size by limiting iterations, but check for accuracy

# 5) then simulate cumulative proportion data to plot against MLE estimates by group
# make lists first
sim_bayes_simlist <- sim_bayes_sim %>% dplyr::group_by(group) %>% dplyr::group_split() 
sim_bayes_countslist <- sim_bayes_counts %>% dplyr::group_by(group) %>% dplyr::group_split() 
bayes_sim_ypred = list() # empty list to population

# simulate data with for loop
for(i in 1:length(sim_bayes_simlist)){
  bayes_sim_ypred[[i]] = sim_bayes_simlist[[i]] %>% dplyr::as_tibble() %>% 
    dplyr::mutate(dw = sim_bayes_countslist[[i]][findInterval(sim_bayes_simlist[[i]]$cumPropsim,
                                                              sim_bayes_countslist[[i]]$cumProp), ]$dw)
}

# 6) Create data frame with simulated data to plot
bayes_sim_ypred_tibble <- dplyr::bind_rows(bayes_sim_ypred) %>% # dots to plot...very large file
  mutate(model = "y_pred")



# 7) combine with raw sims
y_pred_raw = bind_rows(bayes_sim_ypred_tibble %>% separate(group, c("group","sim", sep = "_")) %>% mutate(group = as.numeric(group),
                                                                                                          sim = as.numeric(sim)), 
                       bayes_sim_tibble %>% mutate(model = "y_raw", sim = -1))

# sim_raw = bayes_sim_tibble %>%
#   mutate(model = "y_bayes_sim",
#          sim = -1,
#          site_id = str_sub(group, 1, 4)) %>%
#   mutate(ID = as.integer(as.factor(group))) %>%
#   select(-site_id) %>%
#   right_join(macro_fish_mat %>% ungroup %>% distinct(site_id, ID))



# combine y_raw and y_pred
# y_pred_raw = bind_rows(sim_ypred, sim_raw)


# plot
y_pred_raw %>% 
  # filter(dw != 0) %>% 
  # mutate(ID = as.factor(ID),
  #        sim = as.factor(sim)) %>% 
  ggplot(aes(y = dw, fill = model, x = sim)) + 
  geom_boxplot(aes(group = interaction(model, sim)),
               outlier.shape = NA) + 
  # geom_jitter(width = 0.1, height = 0, size = 0.1) +
  # facet_wrap(~site_id) +
  scale_y_log10() +
  NULL

