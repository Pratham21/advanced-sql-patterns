# advanced-sql-patterns

Production-grade SQL patterns used in real data engineering and analytics work across Fortune 500 companies (Intuit, eBay, Tesla, Verizon).

All queries are written for **BigQuery** and **Hive** with business context explained in comments. No database setup needed — these are reference patterns you can adapt to any warehouse.

---

## 📁 Structure

```
advanced-sql-patterns/
├── window_functions/        # Running totals, ranks, lag/lead, moving averages
├── funnel_analysis/         # Multi-step conversion, drop-off, time-to-convert
├── cohort_analysis/         # Monthly retention cohorts, churn flags
├── churn_analysis/          # 90-day inactivity scoring, churn risk tiers
└── hive_patterns/           # Hive-specific: partitioning, bucketing, optimised HiveQL
```

---

## 🛠️ Tech
![BigQuery](https://img.shields.io/badge/BigQuery-4285F4?style=flat&logo=google-cloud&logoColor=white)
![Hive](https://img.shields.io/badge/Hive-FDEE21?style=flat&logo=apache-hive&logoColor=black)
![SQL](https://img.shields.io/badge/SQL-4479A1?style=flat&logo=postgresql&logoColor=white)

---

## 📌 Highlights

- **Funnel analysis** — tracks lead-to-close conversion with drop-off at each stage
- **Cohort retention** — monthly cohort matrix showing 30/60/90 day retention
- **Churn scoring** — tiered risk model based on recency, frequency, engagement
- **Hive optimisations** — partition pruning, bucketing, ORC format patterns used in Hadoop pipelines at Disney and Verizon

---

*Written by Pratham Bharadwaj — Senior Analytics Engineer with 10+ years at Intuit, eBay, Tesla, HP, Verizon, Disney.*  
🔗 [LinkedIn](https://linkedin.com/in/pratham-bharadwaj-47664371) · [Tableau Public](https://public.tableau.com/app/profile/pratham8634/vizzes)
