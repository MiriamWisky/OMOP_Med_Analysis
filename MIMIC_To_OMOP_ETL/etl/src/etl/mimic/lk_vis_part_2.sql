CREATE TABLE lk_visit_no_hadm_all AS
-- labevents
SELECT src.subject_id                   AS subject_id,
       CAST(src.start_datetime AS DATE) AS date_id,
       src.start_datetime               AS start_datetime,
       --
       src.unit_id                      AS unit_id,
       src.load_table_id                AS load_table_id,
       src.load_row_id                  AS load_row_id,
       src.trace_id::text                     AS trace_id
FROM lk_meas_labevents_mapped src
WHERE src.hadm_id IS NULL
UNION ALL
-- specimen
SELECT src.subject_id                   AS subject_id,
       CAST(src.start_datetime AS DATE) AS date_id,
       src.start_datetime               AS start_datetime,
       --
       src.unit_id                      AS unit_id,
       src.load_table_id                AS load_table_id,
       src.load_row_id                  AS load_row_id,
       src.trace_id                     AS trace_id
FROM lk_specimen_mapped src
WHERE src.hadm_id IS NULL
UNION ALL
-- organism
SELECT src.subject_id                   AS subject_id,
       CAST(src.start_datetime AS DATE) AS date_id,
       src.start_datetime               AS start_datetime,
       --
       src.unit_id                      AS unit_id,
       src.load_table_id                AS load_table_id,
       src.load_row_id                  AS load_row_id,
       src.trace_id                     AS trace_id
FROM lk_meas_organism_mapped src
WHERE src.hadm_id IS NULL
UNION ALL
-- antibiotics
SELECT src.subject_id                   AS subject_id,
       CAST(src.start_datetime AS DATE) AS date_id,
       src.start_datetime               AS start_datetime,
       --
       src.unit_id                      AS unit_id,
       src.load_table_id                AS load_table_id,
       src.load_row_id                  AS load_row_id,
       src.trace_id::text                     AS trace_id
FROM lk_meas_ab_mapped src
WHERE src.hadm_id IS NULL
-- UNION ALL
-- waveforms
-- SELECT src.subject_id                   AS subject_id,
--        CAST(src.start_datetime AS DATE) AS date_id,
--        src.start_datetime               AS start_datetime,
--        --
--        src.unit_id                      AS unit_id,
--        src.load_table_id                AS load_table_id,
--        src.load_row_id                  AS load_row_id,
--        src.trace_id                     AS trace_id
-- FROM lk_meas_waveform_mapped src
-- WHERE src.hadm_id IS NULL
;

-- -------------------------------------------------------------------
-- lk_visit_no_hadm_dist
-- -------------------------------------------------------------------

CREATE TABLE lk_visit_no_hadm_dist AS
SELECT src.subject_id           AS subject_id,
       src.date_id              AS date_id,
       MIN(src.start_datetime)  AS start_datetime,
       MAX(src.start_datetime)  AS end_datetime,
       'AMBULATORY OBSERVATION' AS admission_type,     -- outpatient visit
       CAST(NULL AS text)     AS admission_location, -- to hospital
       CAST(NULL AS text)     AS discharge_location, -- from hospital
       --
       'no_hadm'                AS unit_id,
       'lk_visit_no_hadm_all'   AS load_table_id,
        0                        AS load_row_id,
    --    json_build_object(
    --     'case_id', src.case_id::text,
    --     'date_id', src.date_id::text
    -- ) AS trace_id                    
    --    json_object(
    --            ARRAY['case_id','date_id'],
    --            ARRAY[case_id::text,src.date_id::text]
    --        )          AS trace_id
    json_object(
               ARRAY['date_id'],
               ARRAY[src.date_id::text]
           )          AS trace_id
FROM lk_visit_no_hadm_all src
GROUP BY src.subject_id,
         src.date_id
;


-- -------------------------------------------------------------------
-- lk_visit_detail_waveform_dist
--
-- collect rows without hadm_id from all tables affected by this case:
--      lk_meas_waveform_mapped
-- -------------------------------------------------------------------

-- CREATE TABLE lk_visit_detail_waveform_dist AS
-- SELECT src.subject_id                        AS subject_id,
--        src.hadm_id                           AS hadm_id,
--        CAST(MIN(src.start_datetime) AS DATE) AS date_id,
--        MIN(src.start_datetime)               AS start_datetime,
--        MAX(src.start_datetime)               AS end_datetime,
--        'AMBULATORY OBSERVATION'              AS current_location, -- outpatient visit
--        src.reference_id                      AS reference_id,
--        --
--        'waveforms'                           AS unit_id,
--        'lk_meas_waveform_mapped'             AS load_table_id,
--        0                                     AS load_row_id,
--        json_object(
--                ARRAY['subject_id','hadm_id', 'reference_id'],
--                ARRAY[subject_id::text,hadm_id::text, reference_id::text]
--            )          AS trace_id
-- FROM lk_meas_waveform_mapped src
-- GROUP BY src.subject_id,
--          src.hadm_id,
--          src.reference_id
-- ;

-- -------------------------------------------------------------------
-- lk_visit_clean
-- -------------------------------------------------------------------

CREATE TABLE lk_visit_clean AS
SELECT row_number() OVER ()           AS visit_occurrence_id,
       src.subject_id         AS subject_id,
       src.hadm_id            AS hadm_id,
       CAST(NULL AS DATE)     AS date_id,
       src.start_datetime     AS start_datetime,
       src.end_datetime       AS end_datetime,
       src.admission_type     AS admission_type,     -- current location
       src.admission_location AS admission_location, -- to hospital
       src.discharge_location AS discharge_location, -- from hospital
       concat(
               CAST(src.subject_id AS text), '|',
               CAST(src.hadm_id AS text)
           )                  AS source_value,
       --
       src.unit_id            AS unit_id,
       src.load_table_id      AS load_table_id,
       src.load_row_id        AS load_row_id,
       src.trace_id           AS trace_id
FROM lk_admissions_clean src -- adm
UNION ALL
SELECT row_number() OVER ()           AS visit_occurrence_id,
       src.subject_id         AS subject_id,
       CAST(NULL AS INTEGER)  AS hadm_id,
       src.date_id            AS date_id,
       src.start_datetime     AS start_datetime,
       src.end_datetime       AS end_datetime,
       src.admission_type     AS admission_type,     -- current location
       src.admission_location AS admission_location, -- to hospital
       src.discharge_location AS discharge_location, -- from hospital
       concat(
               CAST(src.subject_id AS text), '|',
               CAST(src.date_id AS text)
           )                  AS source_value,
       --
       src.unit_id            AS unit_id,
       src.load_table_id      AS load_table_id,
       src.load_row_id        AS load_row_id,
       src.trace_id           AS trace_id
FROM lk_visit_no_hadm_dist src -- adm
;

-- -------------------------------------------------------------------
-- lk_visit_detail_clean
--
-- Rule 1. 
-- transfers with valid hadm_id
-- -------------------------------------------------------------------

CREATE TABLE lk_visit_detail_clean AS
SELECT row_number() OVER ()         AS visit_detail_id,
       src.subject_id       AS subject_id,
       src.hadm_id          AS hadm_id,
       src.date_id          AS date_id,
       src.start_datetime   AS start_datetime,
       src.end_datetime     AS end_datetime,     -- if null, populate with next start_datetime
       concat(
               CAST(src.subject_id AS text), '|',
               COALESCE(CAST(src.hadm_id AS text), CAST(src.date_id AS text)), '|',
               CAST(src.transfer_id AS text)
           )                AS source_value,
       src.current_location AS current_location, -- find prev and next for adm and disch location
       --
       src.unit_id          AS unit_id,
       src.load_table_id    AS load_table_id,
       src.load_row_id      AS load_row_id,
       src.trace_id         AS trace_id
FROM lk_transfers_clean src
WHERE src.hadm_id IS NOT NULL -- some ER transfers are excluded because not all of them fit to additional single day visits
;

-- -------------------------------------------------------------------
-- lk_visit_detail_clean
--
-- Rule 2.
-- ER admissions
-- -------------------------------------------------------------------
INSERT INTO lk_visit_detail_clean
SELECT row_number() OVER ()                     AS visit_detail_id,
       src.subject_id                   AS subject_id,
       src.hadm_id                      AS hadm_id,
       CAST(src.start_datetime AS DATE) AS date_id,
       src.start_datetime               AS start_datetime,
       CAST(NULL AS TIMESTAMP)          AS end_datetime,     -- if null, populate with next start_datetime
       concat(
               CAST(src.subject_id AS text), '|',
               CAST(src.hadm_id AS text)
           )                            AS source_value,
       src.admission_type               AS current_location, -- find prev and next for adm and disch location
       --
       src.unit_id                      AS unit_id,
       src.load_table_id                AS load_table_id,
       src.load_row_id                  AS load_row_id,
       src.trace_id                     AS trace_id
FROM lk_admissions_clean src
WHERE src.is_er_admission
;

-- -------------------------------------------------------------------
-- lk_visit_detail_clean
--
-- Rule 3.
-- services
-- -------------------------------------------------------------------
INSERT INTO lk_visit_detail_clean
SELECT row_number() OVER ()                     AS visit_detail_id,
       src.subject_id                   AS subject_id,
       src.hadm_id                      AS hadm_id,
       CAST(src.start_datetime AS DATE)               AS date_id,
       src.start_datetime               AS start_datetime,
       src.end_datetime                 AS end_datetime,
       concat(
               CAST(src.subject_id AS text), '|',
               CAST(src.hadm_id AS text), '|',
               CAST(src.start_datetime AS text)
           )                            AS source_value,
       src.curr_service                 AS current_location,
       CAST(NULL AS text)             AS unit_id,
       src.load_table_id                AS load_table_id,
       src.load_row_id                  AS load_row_id,
       src.trace_id                     AS trace_id
FROM lk_services_clean src
WHERE src.prev_service = src.lag_service -- ensure that the services sequence is still consistent after removing duplicates
;

-- -------------------------------------------------------------------
-- lk_visit_detail_clean
--
-- Rule 4.
-- waveforms
-- -------------------------------------------------------------------
-- INSERT INTO lk_visit_detail_clean
-- SELECT uuid_hash(uuid_nil())         AS visit_detail_id,
--        src.subject_id       AS subject_id,
--        src.hadm_id          AS hadm_id,
--        src.date_id          AS date_id,
--        src.start_datetime   AS start_datetime,
--        src.end_datetime     AS end_datetime,     -- if null, populate with next start_datetime
--        src.reference_id     AS source_value,
--        src.current_location AS current_location, -- find prev and next for adm and disch location
--        --
--        src.unit_id          AS unit_id,
--        src.load_table_id    AS load_table_id,
--        src.load_row_id      AS load_row_id,
--        src.trace_id         AS trace_id
-- FROM lk_visit_detail_waveform_dist src
-- ;

-- -------------------------------------------------------------------
-- lk_visit_detail_prev_next
-- skip "mapped"
-- -------------------------------------------------------------------

CREATE TABLE lk_visit_detail_prev_next AS
SELECT src.visit_detail_id  AS  visit_detail_id,
       src.subject_id       AS  subject_id,
       src.hadm_id          AS  hadm_id,
       src.date_id          AS  date_id,
       src.start_datetime   AS  start_datetime,
       COALESCE(
               src.end_datetime,
               lead(src.start_datetime) over(
                       partition BY src.subject_id, src.hadm_id, src.date_id ORDER BY src.start_datetime ASC
                   ),
               vis.end_datetime
           )                AS  end_datetime,
       src.source_value     AS  source_value,
       --
       src.current_location AS  current_location,
       lag(src.visit_detail_id) over (
        partition BY src.subject_id, src.hadm_id, src.date_id, src.unit_id
        ORDER BY src.start_datetime ASC
    )                                                AS preceding_visit_detail_id, COALESCE(
        lag(src.current_location) over(
                partition BY src.subject_id, src.hadm_id, src.date_id,
                src.unit_id -- double-check if chains follow each other or intercept
                    ORDER BY src.start_datetime ASC
            ),
        vis.admission_location
    ) AS admission_location,
       COALESCE(
               lead(src.current_location) over(
               partition BY src.subject_id, src.hadm_id, src.date_id, src.unit_id ORDER BY src.start_datetime ASC
           ),
               vis.discharge_location
           )                AS  discharge_location,
       --
       src.unit_id          AS  unit_id,
       src.load_table_id    AS  load_table_id,
       src.load_row_id      AS  load_row_id,
       src.trace_id         AS  trace_id
FROM lk_visit_detail_clean src
         LEFT JOIN
     lk_visit_clean vis
     ON src.subject_id = vis.subject_id
         AND (
                    src.hadm_id = vis.hadm_id
                OR src.hadm_id IS NULL AND src.date_id = vis.date_id
            )
;


-- -------------------------------------------------------------------
-- lk_visit_concept
--
-- gcpt_admission_type_to_concept -> mimiciv_vis_admission_type
-- gcpt_admission_location_to_concept -> mimiciv_vis_admission_location
-- gcpt_discharge_location_to_concept -> mimiciv_vis_discharge_location
-- brand new vocabulary -> mimiciv_vis_service
-- gcpt_care_site -> mimiciv_cs_place_of_service
--
-- keep exact values of admission type etc as custom concepts, 
-- then map it to standard Visit concepts
-- -------------------------------------------------------------------

CREATE TABLE lk_visit_concept AS
SELECT vc.concept_code  AS source_code,
       vc.concept_id    AS source_concept_id,
       vc2.concept_id   AS target_concept_id,
       vc.vocabulary_id AS source_vocabulary_id
FROM voc_concept vc
         LEFT JOIN
     voc_concept_relationship vcr
     ON vc.concept_id = vcr.concept_id_1
         AND vcr.relationship_id = 'Maps to'
         LEFT JOIN
     voc_concept vc2
     ON vc2.concept_id = vcr.concept_id_2
         AND vc2.standard_concept = 'S'
         AND vc2.invalid_reason IS NULL
WHERE vc.vocabulary_id IN (
                           'mimiciv_vis_admission_location', -- for admission_location_concept_id (visit and visit_detail)
                           'mimiciv_vis_discharge_location', -- for discharge_location_concept_id
                           'mimiciv_vis_service', -- for admisstion_location_concept_id (visit_detail)
    -- and for discharge_location_concept_id
                           'mimiciv_vis_admission_type', -- for visit_concept_id
                           'mimiciv_cs_place_of_service' -- for visit_detail_concept_id
    )
;