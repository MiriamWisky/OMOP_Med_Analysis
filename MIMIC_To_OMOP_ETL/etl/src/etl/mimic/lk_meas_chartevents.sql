CREATE TABLE lk_chartevents_clean AS
SELECT src.subject_id             AS subject_id,
       src.hadm_id                AS hadm_id,
       src.stay_id                AS stay_id,
       src.itemid                 AS itemid,
       CAST(src.itemid AS text) AS source_code,
       di.label                   AS source_label,
       src.charttime              AS start_datetime,
       TRIM(src.value) AS VALUE,
       CASE
        WHEN TRIM(src.value) ~ '(^[-]?[\d]+[.]?[\d]*[ ]*[a-z]+$)' THEN
            CAST(substring(TRIM(src.value) FROM '([-]?[\d]+[.]?[\d]*)') AS NUMERIC)
        ELSE src.valuenum
    END AS valuenum,
    CASE
        WHEN TRIM(src.value) ~ '(^[-]?[\d]+[.]?[\d]*[ ]*[a-z]+$)' THEN
            TRIM(regexp_replace(TRIM(src.value), '([-]?[\d]+[.]?[\d]*)', '', 'g'))
        ELSE src.valueuom
    END AS valueuom,
    -- CASE WHEN REGEXP_EXTRACT(TRIM(src.value), r'(^[-]?[\d]+[.]?[\d]*[ ]*[a-z]+$)') IS NOT NULL
    --     THEN CAST(REGEXP_EXTRACT(src.value, r'([-]?[\d]+[.]?[\d]*)') AS NUMERIC)
    --     ELSE src.valuenum END AS valuenum,
    -- CASE WHEN REGEXP_EXTRACT(TRIM(src.value), r'(^[-]?[\d]+[.]?[\d]*[ ]*[a-z]+$)') IS NOT NULL
    --     THEN TRIM(REGEXP_REPLACE(src.value, r'(\d+)', ''))
    --     ELSE src.valueuom END   AS valueuom, -- unit of measurement
    --
    'chartevents'           AS unit_id,
    src.load_table_id       AS load_table_id,
    src.load_row_id         AS load_row_id,
    src.trace_id            AS trace_id
FROM
    src_chartevents src -- ce
    INNER JOIN
    src_d_items di
ON src.itemid = di.itemid
WHERE
    di.label NOT LIKE '%Temperature'
   OR di.label LIKE '%Temperature'
  AND (CASE WHEN valueuom LIKE '%F%' THEN (valuenum - 32) * 5 / 9 ELSE valuenum END) BETWEEN 25  AND 44
;

-- -------------------------------------------------------------------
-- tmp_chartevents_code_dist
-- it is a temporary table to collect distinct codes to be mapped
-- we are going to store source_code, source_label, and row_count in the concept lookup table,
-- to provide enough information for a mapping team for possible future mapping
--
-- brand new custom vocabulary -> mimiciv_meas_chart
-- brand new custom vocabulary -> mimiciv_meas_chartevents_value
-- -------------------------------------------------------------------

CREATE TABLE tmp_chartevents_code_dist AS
-- source codes to be mapped
SELECT itemid               AS itemid,
       source_code          AS source_code,
       source_label         AS source_label,
       'mimiciv_meas_chart' AS source_vocabulary_id,
       COUNT(*)             AS row_count
FROM lk_chartevents_clean
GROUP BY itemid,
         source_code,
         source_label
UNION ALL
-- values to be mapped
SELECT CAST(NULL AS INTEGER)            AS itemid,
       value                            AS source_code,
       value                            AS source_label,
       'mimiciv_meas_chartevents_value' AS source_vocabulary_id, -- both obs values and conditions
       COUNT(*)                         AS row_count
FROM lk_chartevents_clean
GROUP BY
         value
;

-- -------------------------------------------------------------------
-- lk_chartevents_concept
-- collect the mapping and keep source_code, source_label, and row_count
-- for possible future mapping
-- -------------------------------------------------------------------

CREATE TABLE lk_chartevents_concept AS
SELECT src.itemid               AS itemid,
       src.source_code          AS source_code,
       src.source_label         AS source_label,
       src.source_vocabulary_id AS source_vocabulary_id,
       -- source concept
       vc.domain_id             AS source_domain_id,
       vc.concept_id            AS source_concept_id,
       -- target concept
       vc2.domain_id            AS target_domain_id,
       vc2.concept_id           AS target_concept_id,
       src.row_count            AS row_count
FROM tmp_chartevents_code_dist src
         LEFT JOIN
     voc_concept vc
     ON vc.concept_code = src.source_code
         AND vc.vocabulary_id = src.source_vocabulary_id
         LEFT JOIN
     voc_concept_relationship vcr
     ON vc.concept_id = vcr.concept_id_1
         AND vcr.relationship_id = 'Maps to'
         LEFT JOIN
     voc_concept vc2
     ON vc2.concept_id = vcr.concept_id_2
         AND vc2.standard_concept = 'S'
         AND vc2.invalid_reason IS NULL
;

DROP TABLE if EXISTS tmp_chartevents_code_dist;

-- -------------------------------------------------------------------
-- lk_chartevents_mapped
-- src_chartevents to measurement and measurement value
-- -------------------------------------------------------------------

CREATE TABLE lk_chartevents_mapped AS
SELECT row_number() OVER ()                                AS measurement_id,
       src.subject_id                              AS subject_id,
       src.hadm_id                                 AS hadm_id,
       src.stay_id                                 AS stay_id,
       src.start_datetime                          AS start_datetime,
       32817                                       AS type_concept_id,   -- OMOP4976890 EHR
       src.itemid                                  AS itemid,
       src.source_code                             AS source_code,
       src.source_label                            AS source_label,
       c_main.source_vocabulary_id                 AS source_vocabulary_id,
       c_main.source_domain_id                     AS source_domain_id,
       c_main.source_concept_id                    AS source_concept_id,
       c_main.target_domain_id                     AS target_domain_id,
       c_main.target_concept_id                    AS target_concept_id,
       src.value                                   AS value_source_value,
       CASE WHEN
               (CASE WHEN src.valuenum IS NULL THEN src.value END) IS NOT NULL
               THEN COALESCE(c_value.target_concept_id, 0)
       END
                                                   AS value_as_concept_id,
       src.valuenum                                AS value_as_number,
       src.valueuom                                AS unit_source_value, -- unit of measurement
       CASE WHEN src.valueuom IS NOT NULL THEN COALESCE(uc.target_concept_id, 0) END AS unit_concept_id,
       --
       concat('meas.', src.unit_id)                AS unit_id,
       src.load_table_id                           AS load_table_id,
       src.load_row_id                             AS load_row_id,
       src.trace_id                                AS trace_id
FROM lk_chartevents_clean src -- ce
         LEFT JOIN
     lk_chartevents_concept c_main -- main
     ON c_main.source_code = src.source_code
         AND c_main.source_vocabulary_id = 'mimiciv_meas_chart'
         LEFT JOIN
     lk_chartevents_concept c_value -- values for main
     ON c_value.source_code = src.value
         AND c_value.source_vocabulary_id = 'mimiciv_meas_chartevents_value'
         AND c_value.target_domain_id = 'Meas Value'
         LEFT JOIN
     lk_meas_unit_concept uc
     ON uc.source_code = src.valueuom
;


-- -------------------------------------------------------------------
-- lk_chartevents_condition_mapped
-- src_chartevents to condition
-- -------------------------------------------------------------------

CREATE TABLE lk_chartevents_condition_mapped AS
SELECT src.subject_id               AS subject_id,
       src.hadm_id                  AS hadm_id,
       src.stay_id                  AS stay_id,
       src.start_datetime           AS start_datetime,
       src.value                    AS source_code,
       c_main.source_vocabulary_id  AS source_vocabulary_id,
       c_main.source_concept_id     AS source_concept_id,
       c_main.target_domain_id      AS target_domain_id,
       c_main.target_concept_id     AS target_concept_id,
       --
       concat('cond.', src.unit_id) AS unit_id,
       src.load_table_id            AS load_table_id,
       src.load_row_id              AS load_row_id,
       src.trace_id                 AS trace_id
FROM lk_chartevents_clean src -- ce
         INNER JOIN
     lk_chartevents_concept c_main -- condition domain from values, mapped
     ON c_main.source_code = src.value
         AND c_main.source_vocabulary_id = 'mimiciv_meas_chartevents_value'
         AND c_main.target_domain_id = 'Condition'
;

