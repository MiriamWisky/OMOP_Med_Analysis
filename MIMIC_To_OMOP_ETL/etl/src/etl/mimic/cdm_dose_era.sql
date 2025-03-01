DROP TABLE IF EXISTS cdm_dose_era;

CREATE TABLE cdm_dose_era
(
    dose_era_id           INTEGER     NOT NULL ,
    person_id             INTEGER     NOT NULL ,
    drug_concept_id       INTEGER     NOT NULL ,
    unit_concept_id       INTEGER     NOT NULL ,
    dose_value            NUMERIC   NOT NULL ,
    dose_era_start_date   DATE      NOT NULL ,
    dose_era_end_date     DATE      NOT NULL ,
    -- 
    unit_id                       text,
    load_table_id                 text,
    load_row_id                   INTEGER
)
;

-- -------------------------------------------------------------------
-- Create Temporary Table: tmp_drugIngredientExp
-- -------------------------------------------------------------------

-- -------------------------------------------------------------------
-- collect Drug Exposures
-- -------------------------------------------------------------------
CREATE TABLE tmp_drugIngredientExp AS
SELECT de.drug_exposure_id            AS drug_exposure_id,
       de.person_id                   AS person_id,
       de.drug_exposure_start_date    AS drug_exposure_start_date,
       de.drug_exposure_end_date      AS drug_exposure_end_date,
       de.drug_concept_id             AS drug_concept_id,
       ds.ingredient_concept_id       AS ingredient_concept_id,
       de.refills                     AS refills,
       CASE
           WHEN de.days_supply = 0 THEN 1
           ELSE de.days_supply
           END                        AS days_supply,
       de.quantity                    AS quantity,
       ds.box_size                    AS box_size,
       ds.amount_value                AS amount_value,
       ds.amount_unit_concept_id      AS amount_unit_concept_id,
       ds.numerator_value             AS numerator_value,
       ds.numerator_unit_concept_id   AS numerator_unit_concept_id,
       ds.denominator_value           AS denominator_value,
       ds.denominator_unit_concept_id AS denominator_unit_concept_id,
       c.concept_class_id             AS concept_class_id
FROM cdm_drug_exposure de
         INNER JOIN voc_drug_strength ds
                    ON de.drug_concept_id = ds.drug_concept_id
         INNER JOIN voc_concept_ancestor ca
                    ON de.drug_concept_id = ca.descendant_concept_id
                        AND ds.ingredient_concept_id = ca.ancestor_concept_id
         LEFT JOIN voc_concept c
                   ON de.drug_concept_id = concept_id
                       AND c.vocabulary_id IN ('RxNorm', 'RxNorm Extension')
;


CREATE TABLE tmp_drugWithDose AS
SELECT drug_exposure_id         AS drug_exposure_id,
       person_id                AS person_id,
       drug_exposure_start_date AS drug_exposure_start_date,
       drug_exposure_end_date   AS drug_exposure_end_date,
       ingredient_concept_id    AS drug_concept_id,
       refills                  AS refills,
       days_supply              AS days_supply,
       quantity                 AS quantity,
       -- CASE 1
       CASE
           WHEN amount_value IS NOT NULL
               AND denominator_unit_concept_id IS NULL
               THEN
               CASE
                   WHEN quantity > 0
                       AND box_size IS NOT NULL
                       AND concept_class_id IN ('Branded Drug Box', 'Clinical Drug Box', 'Marketed Product',
                                                'Quant Branded Box', 'Quant Clinical Box')
                       THEN amount_value * quantity * box_size / days_supply
                   WHEN quantity > 0
                       AND concept_class_id NOT IN ('Branded Drug Box', 'Clinical Drug Box', 'Marketed Product',
                                                    'Quant Branded Box', 'Quant Clinical Box')
                       THEN amount_value * quantity / days_supply
                   WHEN quantity = 0 AND box_size IS NOT NULL
                       THEN amount_value * box_size / days_supply
                   WHEN quantity = 0 AND box_size IS NULL
                       THEN -1
                   END
           -- CASE 2, 3
           WHEN numerator_value IS NOT NULL
               AND concept_class_id != 'Ingredient'
           AND denominator_unit_concept_id != 8505     --hour
        THEN
            CASE
                WHEN denominator_value IS NOT NULL
                THEN numerator_value / days_supply
                WHEN denominator_value IS NULL AND quantity != 0
                THEN numerator_value * quantity / days_supply
                WHEN denominator_value IS NULL AND quantity = 0
                THEN -1
END
        -- CASE 4
WHEN numerator_value IS NOT NULL
            AND concept_class_id = 'Ingredient'
            AND denominator_unit_concept_id != 8505
        THEN
            CASE
                WHEN quantity > 0
                THEN quantity / days_supply
                WHEN quantity = 0
                THEN -1
END
        -- CASE 6
WHEN numerator_value IS NOT NULL
            AND denominator_unit_concept_id = 8505
        THEN
            CASE
                WHEN denominator_value IS NOT NULL
                THEN numerator_value * 24 / denominator_value
                WHEN denominator_value IS NULL AND quantity != 0
                THEN numerator_value * 24 / quantity
                WHEN denominator_value IS NULL AND quantity = 0
                THEN -1
END
END
AS dose_value,
    -- CASE 1
    CASE
        WHEN amount_value IS NOT NULL
            AND denominator_unit_concept_id IS NULL
        THEN
            CASE
                WHEN quantity = 0 AND box_size IS NULL
                THEN -1
                ELSE amount_unit_concept_id
END
        -- CASE 2, 3
WHEN numerator_value IS NOT NULL
            AND concept_class_id != 'Ingredient'
            AND denominator_unit_concept_id != 8505     --hour
        THEN
            CASE
                WHEN denominator_value IS NULL AND quantity = 0
                THEN -1
                ELSE numerator_unit_concept_id
END
        -- CASE 4
WHEN numerator_value IS NOT NULL
            AND concept_class_id = 'Ingredient'
            AND denominator_unit_concept_id != 8505
        THEN
            CASE
                WHEN quantity > 0
                THEN 0
                WHEN quantity = 0
                THEN -1
END
        -- CASE 6
WHEN numerator_value IS NOT NULL
            AND denominator_unit_concept_id = 8505
        THEN
            CASE
            WHEN denominator_value IS NULL AND quantity = 0
            THEN -1
            ELSE numerator_unit_concept_id
END
END
AS unit_concept_id
FROM tmp_drugIngredientExp
;

CREATE TABLE tmp_cteDoseTarget AS
SELECT dwd.drug_exposure_id                                         AS drug_exposure_id,
       dwd.person_id                                                AS person_id,
       dwd.drug_concept_id                                          AS drug_concept_id,
       dwd.unit_concept_id                                          AS unit_concept_id,
       dwd.dose_value                                               AS dose_value,
       dwd.drug_exposure_start_date                                 AS drug_exposure_start_date,
       dwd.days_supply                                              AS days_supply,
    --    COALESCE(drug_exposure_end_date,
    --        -- If drug_exposure_end_date != NULL,
    --        -- return drug_exposure_end_date, otherwise go to next case
    --             NULLIF(drug_exposure_start_date + INTERVAL '1 day' * (1 * days_supply * (COALESCE(refills, 0) + 1))),
    --                    drug_exposure_start_date)
    --        --If days_supply != NULL or 0, return drug_exposure_start_date + days_supply,
    --        -- otherwise go to next case
    --             drug_exposure_start_date + INTERVAL '1 day' AS drug_exposure_end_date
        COALESCE(drug_exposure_end_date,
           -- If drug_exposure_end_date != NULL,
           -- return drug_exposure_end_date, otherwise go to next case
                NULLIF(drug_exposure_start_date + INTERVAL '1 day' * (1 * days_supply * (COALESCE(refills, 0) + 1)),
                       drug_exposure_start_date),
           --If days_supply != NULL or 0, return drug_exposure_start_date + days_supply,
           -- otherwise go to next case
                drug_exposure_start_date + INTERVAL '1 day') AS drug_exposure_end_date
-- Add 1 day to the drug_exposure_start_date since
-- there is no end_date or INTERVAL for the days_supply
FROM tmp_drugwithdose dwd
WHERE dose_value <> -1
;


CREATE TABLE tmp_cteDoseEndDates_rawdata AS
SELECT person_id                AS person_id,
       drug_concept_id          AS drug_concept_id,
       unit_concept_id          AS unit_concept_id,
       dose_value               AS dose_value,
       drug_exposure_start_date AS event_date,
       -1                       AS event_type,
       row_number()                over (
        partition BY person_id, drug_concept_id, unit_concept_id, CAST(dose_value AS INTEGER)
        ORDER BY drug_exposure_start_date)          AS start_ordinal
FROM tmp_ctedosetarget
UNION ALL
-- pad the end dates by 30 to allow a grace period for overlapping ranges.
SELECT person_id                                         AS person_id,
       drug_concept_id                                   AS drug_concept_id,
       unit_concept_id                                   AS unit_concept_id,
       dose_value                                        AS dose_value,
       drug_exposure_end_date + 30 * INTERVAL '1 day'    AS event_date,
       1                                                 AS event_type,
       NULL                                              AS start_ordinal
FROM tmp_ctedosetarget
;

CREATE TABLE tmp_cteDoseEndDates_e AS
SELECT person_id       AS person_id,
       drug_concept_id AS drug_concept_id,
       unit_concept_id AS unit_concept_id,
       dose_value      AS dose_value,
       event_date      AS event_date,
       event_type      AS event_type,
       MAX(start_ordinal) over (
        partition BY person_id, drug_concept_id, unit_concept_id, CAST(dose_value AS INTEGER) -- double-check if it is a valid cast
        ORDER BY event_date, event_type)               AS start_ordinal, row_number() over (
        partition BY person_id, drug_concept_id, unit_concept_id, CAST(dose_value AS INTEGER)
        ORDER BY event_date, event_type)                                        AS overall_ord
-- order by above pulls the current START down from the prior
-- rows so that the NULLs from the END DATES will contain a value we can compare with
FROM tmp_ctedoseenddates_rawdata
;

CREATE TABLE tmp_cteDoseEndDates AS
SELECT person_id                             AS person_id,
       drug_concept_id                       AS drug_concept_id,
       unit_concept_id                       AS unit_concept_id,
       dose_value                            AS dose_value,
    --    date_sub(event_date, 30) AS end_date -- unpad the end date
    event_date - INTERVAL '30 days' AS end_date -- unpad the end date
FROM tmp_ctedoseenddates_e
WHERE (2 * start_ordinal) - overall_ord = 0
;


CREATE TABLE tmp_cteDoseFinalEnds AS
SELECT dt.person_id                AS person_id,
       dt.drug_concept_id          AS drug_concept_id,
       dt.unit_concept_id          AS unit_concept_id,
       dt.dose_value               AS dose_value,
       dt.drug_exposure_start_date AS drug_exposure_start_date,
       MIN(e.end_date)             AS drug_era_end_date
FROM tmp_ctedosetarget dt
         INNER JOIN tmp_ctedoseenddates e
                    ON dt.person_id = e.person_id
                        AND dt.drug_concept_id = e.drug_concept_id
                        AND dt.unit_concept_id = e.unit_concept_id
                        AND dt.drug_concept_id = e.drug_concept_id
                        AND dt.dose_value = e.dose_value
                        AND e.end_date >= dt.drug_exposure_start_date
GROUP BY dt.drug_exposure_id,
         dt.person_id,
         dt.drug_concept_id,
         dt.drug_exposure_start_date,
         dt.unit_concept_id,
         dt.dose_value
;

INSERT INTO cdm_dose_era
SELECT row_number() OVER ()                  AS dose_era_id,
       person_id                     AS person_id,
       drug_concept_id               AS drug_concept_id,
       unit_concept_id               AS unit_concept_id,
       dose_value                    AS dose_value,
       MIN(drug_exposure_start_date) AS dose_era_start_date,
       drug_era_end_date             AS dose_era_end_date,
       'dose_era.drug_exposure'      AS unit_id,
       CAST(NULL AS text)          AS load_table_id,
       CAST(NULL AS INTEGER)         AS load_row_id
FROM tmp_ctedosefinalends
GROUP BY person_id,
         drug_concept_id,
         unit_concept_id,
         dose_value,
         drug_era_end_date
ORDER BY person_id,
         drug_concept_id
;

-- -------------------------------------------------------------------
-- Drop Temporary Tables
-- -------------------------------------------------------------------
DROP TABLE if EXISTS tmp_drugIngredientExp;
DROP TABLE if EXISTS tmp_drugWithDose;
DROP TABLE if EXISTS tmp_cteDoseTarget;
DROP TABLE if EXISTS tmp_cteDoseEndDates_rawdata;
DROP TABLE if EXISTS tmp_cteDoseEndDates_e;
DROP TABLE if EXISTS tmp_cteDoseEndDates;
DROP TABLE if EXISTS tmp_cteDoseFinalEnds;

