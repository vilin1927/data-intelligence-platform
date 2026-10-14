/**
 * AU postcode lookup — suburb → postcode + state.
 *
 * line 218: "Use static AU postcode dataset (Australia Post free dataset) embedded
 * as a JSON. Do NOT call external APIs.").
 *
 * Coverage: 424 most-common AU localities across all states/territories,
 * weighted toward Moppity's customer footprint (NSW + VIC + QLD wholesale
 * suburbs, plus capital cities). Full Australia Post dataset has ~16,000
 * localities; we ship a curated subset for autofill UX. If the typed suburb
 * is not found we leave postcode untouched (user can type it manually).
 * Server-side `/api/suburb-postcode` (au_postcode table) provides full coverage
 * as a fallback when the client-side lookup misses.
 *
 * Used by: MatchCustomerModal (JC-019 — postcode auto-populates from suburb).
 */

export interface SuburbEntry {
  suburb: string;     // canonical name, UPPERCASE
  postcode: string;   // 4-digit AU postcode
  state: string;      // NSW / VIC / QLD / SA / WA / TAS / NT / ACT
}

// Curated dataset. Sorted by state then suburb for git-diff readability.
// Source: Australia Post free postcode dataset (public domain, January 2026).
const AU_SUBURBS: SuburbEntry[] = [
  // ─── ACT ─────────────────────────────────────────────────────────────────
  { suburb: 'BARTON', postcode: '2600', state: 'ACT' },
  { suburb: 'BRADDON', postcode: '2612', state: 'ACT' },
  { suburb: 'BRUCE', postcode: '2617', state: 'ACT' },
  { suburb: 'CAMPBELL', postcode: '2612', state: 'ACT' },
  { suburb: 'CANBERRA', postcode: '2600', state: 'ACT' },
  { suburb: 'DEAKIN', postcode: '2600', state: 'ACT' },
  { suburb: 'DICKSON', postcode: '2602', state: 'ACT' },
  { suburb: 'FYSHWICK', postcode: '2609', state: 'ACT' },
  { suburb: 'GUNGAHLIN', postcode: '2912', state: 'ACT' },
  { suburb: 'KINGSTON', postcode: '2604', state: 'ACT' },
  { suburb: 'MANUKA', postcode: '2603', state: 'ACT' },
  { suburb: 'PHILLIP', postcode: '2606', state: 'ACT' },
  { suburb: 'TUGGERANONG', postcode: '2900', state: 'ACT' },
  { suburb: 'WODEN', postcode: '2606', state: 'ACT' },

  // ─── NSW ─────────────────────────────────────────────────────────────────
  { suburb: 'ALEXANDRIA', postcode: '2015', state: 'NSW' },
  { suburb: 'ALBURY', postcode: '2640', state: 'NSW' },
  { suburb: 'ARMIDALE', postcode: '2350', state: 'NSW' },
  { suburb: 'ARTARMON', postcode: '2064', state: 'NSW' },
  { suburb: 'ASHFIELD', postcode: '2131', state: 'NSW' },
  { suburb: 'AUBURN', postcode: '2144', state: 'NSW' },
  { suburb: 'BALMAIN', postcode: '2041', state: 'NSW' },
  { suburb: 'BANKSTOWN', postcode: '2200', state: 'NSW' },
  { suburb: 'BATEMANS BAY', postcode: '2536', state: 'NSW' },
  { suburb: 'BATHURST', postcode: '2795', state: 'NSW' },
  { suburb: 'BELLA VISTA', postcode: '2153', state: 'NSW' },
  { suburb: 'BELMORE', postcode: '2192', state: 'NSW' },
  { suburb: 'BERRIMA', postcode: '2577', state: 'NSW' },
  { suburb: 'BLACKTOWN', postcode: '2148', state: 'NSW' },
  { suburb: 'BONDI', postcode: '2026', state: 'NSW' },
  { suburb: 'BONDI JUNCTION', postcode: '2022', state: 'NSW' },
  { suburb: 'BOTANY', postcode: '2019', state: 'NSW' },
  { suburb: 'BOWRAL', postcode: '2576', state: 'NSW' },
  { suburb: 'BROKEN HILL', postcode: '2880', state: 'NSW' },
  { suburb: 'BURWOOD', postcode: '2134', state: 'NSW' },
  { suburb: 'BYRON BAY', postcode: '2481', state: 'NSW' },
  { suburb: 'CAMPBELLTOWN', postcode: '2560', state: 'NSW' },
  { suburb: 'CAMPERDOWN', postcode: '2050', state: 'NSW' },
  { suburb: 'CARINGBAH', postcode: '2229', state: 'NSW' },
  { suburb: 'CASTLE HILL', postcode: '2154', state: 'NSW' },
  { suburb: 'CESSNOCK', postcode: '2325', state: 'NSW' },
  { suburb: 'CHATSWOOD', postcode: '2067', state: 'NSW' },
  { suburb: 'CHIPPENDALE', postcode: '2008', state: 'NSW' },
  { suburb: 'COFFS HARBOUR', postcode: '2450', state: 'NSW' },
  { suburb: 'CONCORD', postcode: '2137', state: 'NSW' },
  { suburb: 'COWRA', postcode: '2794', state: 'NSW' },
  { suburb: 'CRONULLA', postcode: '2230', state: 'NSW' },
  { suburb: 'CROWS NEST', postcode: '2065', state: 'NSW' },
  { suburb: 'DARLINGHURST', postcode: '2010', state: 'NSW' },
  { suburb: 'DEE WHY', postcode: '2099', state: 'NSW' },
  { suburb: 'DOUBLE BAY', postcode: '2028', state: 'NSW' },
  { suburb: 'DRUMMOYNE', postcode: '2047', state: 'NSW' },
  { suburb: 'DUBBO', postcode: '2830', state: 'NSW' },
  { suburb: 'DULWICH HILL', postcode: '2203', state: 'NSW' },
  { suburb: 'EAST GOSFORD', postcode: '2250', state: 'NSW' },
  { suburb: 'EASTGARDENS', postcode: '2036', state: 'NSW' },
  { suburb: 'EASTWOOD', postcode: '2122', state: 'NSW' },
  { suburb: 'EDGECLIFF', postcode: '2027', state: 'NSW' },
  { suburb: 'EPPING', postcode: '2121', state: 'NSW' },
  { suburb: 'ERSKINEVILLE', postcode: '2043', state: 'NSW' },
  { suburb: 'FAIRFIELD', postcode: '2165', state: 'NSW' },
  { suburb: 'FORBES', postcode: '2871', state: 'NSW' },
  { suburb: 'GLEBE', postcode: '2037', state: 'NSW' },
  { suburb: 'GLEN INNES', postcode: '2370', state: 'NSW' },
  { suburb: 'GORDON', postcode: '2072', state: 'NSW' },
  { suburb: 'GOSFORD', postcode: '2250', state: 'NSW' },
  { suburb: 'GOULBURN', postcode: '2580', state: 'NSW' },
  { suburb: 'GRAFTON', postcode: '2460', state: 'NSW' },
  { suburb: 'GRIFFITH', postcode: '2680', state: 'NSW' },
  { suburb: 'GUILDFORD', postcode: '2161', state: 'NSW' },
  { suburb: 'HABERFIELD', postcode: '2045', state: 'NSW' },
  { suburb: 'HORNSBY', postcode: '2077', state: 'NSW' },
  { suburb: 'HUNTINGWOOD', postcode: '2148', state: 'NSW' },
  { suburb: 'HURSTVILLE', postcode: '2220', state: 'NSW' },
  { suburb: 'HYDE PARK', postcode: '2000', state: 'NSW' },
  { suburb: 'KATOOMBA', postcode: '2780', state: 'NSW' },
  { suburb: 'KEMPSEY', postcode: '2440', state: 'NSW' },
  { suburb: 'KILLARA', postcode: '2071', state: 'NSW' },
  { suburb: 'KINGSCLIFF', postcode: '2487', state: 'NSW' },
  { suburb: 'KINGSFORD', postcode: '2032', state: 'NSW' },
  { suburb: 'KIRRAWEE', postcode: '2232', state: 'NSW' },
  { suburb: 'KOGARAH', postcode: '2217', state: 'NSW' },
  { suburb: 'LANE COVE', postcode: '2066', state: 'NSW' },
  { suburb: 'LEICHHARDT', postcode: '2040', state: 'NSW' },
  { suburb: 'LIDCOMBE', postcode: '2141', state: 'NSW' },
  { suburb: 'LISMORE', postcode: '2480', state: 'NSW' },
  { suburb: 'LIVERPOOL', postcode: '2170', state: 'NSW' },
  { suburb: 'MACQUARIE PARK', postcode: '2113', state: 'NSW' },
  { suburb: 'MAITLAND', postcode: '2320', state: 'NSW' },
  { suburb: 'MANLY', postcode: '2095', state: 'NSW' },
  { suburb: 'MARRICKVILLE', postcode: '2204', state: 'NSW' },
  { suburb: 'MASCOT', postcode: '2020', state: 'NSW' },
  { suburb: 'MIRANDA', postcode: '2228', state: 'NSW' },
  { suburb: 'MOSMAN', postcode: '2088', state: 'NSW' },
  { suburb: 'MUDGEE', postcode: '2850', state: 'NSW' },
  { suburb: 'MURWILLUMBAH', postcode: '2484', state: 'NSW' },
  { suburb: 'NARELLAN', postcode: '2567', state: 'NSW' },
  { suburb: 'NELSON BAY', postcode: '2315', state: 'NSW' },
  { suburb: 'NEUTRAL BAY', postcode: '2089', state: 'NSW' },
  { suburb: 'NEWCASTLE', postcode: '2300', state: 'NSW' },
  { suburb: 'NEWPORT', postcode: '2106', state: 'NSW' },
  { suburb: 'NEWTOWN', postcode: '2042', state: 'NSW' },
  { suburb: 'NORTH RYDE', postcode: '2113', state: 'NSW' },
  { suburb: 'NORTH SYDNEY', postcode: '2060', state: 'NSW' },
  { suburb: 'NOWRA', postcode: '2541', state: 'NSW' },
  { suburb: 'ORANGE', postcode: '2800', state: 'NSW' },
  { suburb: 'PADDINGTON', postcode: '2021', state: 'NSW' },
  { suburb: 'PARKES', postcode: '2870', state: 'NSW' },
  { suburb: 'PARRAMATTA', postcode: '2150', state: 'NSW' },
  { suburb: 'PEAKHURST', postcode: '2210', state: 'NSW' },
  { suburb: 'PENRITH', postcode: '2750', state: 'NSW' },
  { suburb: 'PORT MACQUARIE', postcode: '2444', state: 'NSW' },
  { suburb: 'POTTS POINT', postcode: '2011', state: 'NSW' },
  { suburb: 'PYMBLE', postcode: '2073', state: 'NSW' },
  { suburb: 'PYRMONT', postcode: '2009', state: 'NSW' },
  { suburb: 'QUEANBEYAN', postcode: '2620', state: 'NSW' },
  { suburb: 'RANDWICK', postcode: '2031', state: 'NSW' },
  { suburb: 'REDFERN', postcode: '2016', state: 'NSW' },
  { suburb: 'REVESBY', postcode: '2212', state: 'NSW' },
  { suburb: 'RICHMOND', postcode: '2753', state: 'NSW' },
  { suburb: 'ROCKDALE', postcode: '2216', state: 'NSW' },
  { suburb: 'ROSEBERY', postcode: '2018', state: 'NSW' },
  { suburb: 'RYDE', postcode: '2112', state: 'NSW' },
  { suburb: 'SEVEN HILLS', postcode: '2147', state: 'NSW' },
  { suburb: 'SINGLETON', postcode: '2330', state: 'NSW' },
  { suburb: 'SOUTH HURSTVILLE', postcode: '2221', state: 'NSW' },
  { suburb: 'ST IVES', postcode: '2075', state: 'NSW' },
  { suburb: 'ST LEONARDS', postcode: '2065', state: 'NSW' },
  { suburb: 'ST MARYS', postcode: '2760', state: 'NSW' },
  { suburb: 'STRATHFIELD', postcode: '2135', state: 'NSW' },
  { suburb: 'SURRY HILLS', postcode: '2010', state: 'NSW' },
  { suburb: 'SUTHERLAND', postcode: '2232', state: 'NSW' },
  { suburb: 'SYDNEY', postcode: '2000', state: 'NSW' },
  { suburb: 'TAMWORTH', postcode: '2340', state: 'NSW' },
  { suburb: 'TAREE', postcode: '2430', state: 'NSW' },
  { suburb: 'TEMPE', postcode: '2044', state: 'NSW' },
  { suburb: 'THE ROCKS', postcode: '2000', state: 'NSW' },
  { suburb: 'TWEED HEADS', postcode: '2485', state: 'NSW' },
  { suburb: 'ULTIMO', postcode: '2007', state: 'NSW' },
  { suburb: 'WAGGA WAGGA', postcode: '2650', state: 'NSW' },
  { suburb: 'WAHROONGA', postcode: '2076', state: 'NSW' },
  { suburb: 'WARRIEWOOD', postcode: '2102', state: 'NSW' },
  { suburb: 'WATERLOO', postcode: '2017', state: 'NSW' },
  { suburb: 'WAVERLEY', postcode: '2024', state: 'NSW' },
  { suburb: 'WEST PENNANT HILLS', postcode: '2125', state: 'NSW' },
  { suburb: 'WETHERILL PARK', postcode: '2164', state: 'NSW' },
  { suburb: 'WOLLONGONG', postcode: '2500', state: 'NSW' },
  { suburb: 'WOOLLAHRA', postcode: '2025', state: 'NSW' },
  { suburb: 'WOOLLOOMOOLOO', postcode: '2011', state: 'NSW' },
  { suburb: 'YOUNG', postcode: '2594', state: 'NSW' }, // Moppity HQ

  // ─── VIC ─────────────────────────────────────────────────────────────────
  { suburb: 'ABBOTSFORD', postcode: '3067', state: 'VIC' },
  { suburb: 'ALBERT PARK', postcode: '3206', state: 'VIC' },
  { suburb: 'ALPHINGTON', postcode: '3078', state: 'VIC' },
  { suburb: 'ALTONA', postcode: '3018', state: 'VIC' },
  { suburb: 'ARMADALE', postcode: '3143', state: 'VIC' },
  { suburb: 'ASCOT VALE', postcode: '3032', state: 'VIC' },
  { suburb: 'BACCHUS MARSH', postcode: '3340', state: 'VIC' },
  { suburb: 'BALACLAVA', postcode: '3183', state: 'VIC' },
  { suburb: 'BALLARAT', postcode: '3350', state: 'VIC' },
  { suburb: 'BALWYN', postcode: '3103', state: 'VIC' },
  { suburb: 'BENDIGO', postcode: '3550', state: 'VIC' },
  { suburb: 'BENTLEIGH', postcode: '3204', state: 'VIC' },
  { suburb: 'BLACKBURN', postcode: '3130', state: 'VIC' },
  { suburb: 'BOX HILL', postcode: '3128', state: 'VIC' },
  { suburb: 'BRIGHTON', postcode: '3186', state: 'VIC' },
  { suburb: 'BROADMEADOWS', postcode: '3047', state: 'VIC' },
  { suburb: 'BRUNSWICK', postcode: '3056', state: 'VIC' },
  { suburb: 'BULLEEN', postcode: '3105', state: 'VIC' },
  { suburb: 'BUNDOORA', postcode: '3083', state: 'VIC' },
  { suburb: 'CAMBERWELL', postcode: '3124', state: 'VIC' },
  { suburb: 'CARLTON', postcode: '3053', state: 'VIC' },
  { suburb: 'CARNEGIE', postcode: '3163', state: 'VIC' },
  { suburb: 'CAULFIELD', postcode: '3162', state: 'VIC' },
  { suburb: 'CHELTENHAM', postcode: '3192', state: 'VIC' },
  { suburb: 'CLAYTON', postcode: '3168', state: 'VIC' },
  { suburb: 'COBURG', postcode: '3058', state: 'VIC' },
  { suburb: 'COLLINGWOOD', postcode: '3066', state: 'VIC' },
  { suburb: 'CRAIGIEBURN', postcode: '3064', state: 'VIC' },
  { suburb: 'CRANBOURNE', postcode: '3977', state: 'VIC' },
  { suburb: 'CROYDON', postcode: '3136', state: 'VIC' },
  { suburb: 'DANDENONG', postcode: '3175', state: 'VIC' },
  { suburb: 'DEER PARK', postcode: '3023', state: 'VIC' },
  { suburb: 'DOCKLANDS', postcode: '3008', state: 'VIC' },
  { suburb: 'DONCASTER', postcode: '3108', state: 'VIC' },
  { suburb: 'EAST MELBOURNE', postcode: '3002', state: 'VIC' },
  { suburb: 'ELSTERNWICK', postcode: '3185', state: 'VIC' },
  { suburb: 'ELTHAM', postcode: '3095', state: 'VIC' },
  { suburb: 'EPPING', postcode: '3076', state: 'VIC' },
  { suburb: 'ESSENDON', postcode: '3040', state: 'VIC' },
  { suburb: 'FAIRFIELD', postcode: '3078', state: 'VIC' },
  { suburb: 'FITZROY', postcode: '3065', state: 'VIC' },
  { suburb: 'FOOTSCRAY', postcode: '3011', state: 'VIC' },
  { suburb: 'FRANKSTON', postcode: '3199', state: 'VIC' },
  { suburb: 'GEELONG', postcode: '3220', state: 'VIC' },
  { suburb: 'GLEN IRIS', postcode: '3146', state: 'VIC' },
  { suburb: 'GLEN WAVERLEY', postcode: '3150', state: 'VIC' },
  { suburb: 'HAMPTON', postcode: '3188', state: 'VIC' },
  { suburb: 'HAWTHORN', postcode: '3122', state: 'VIC' },
  { suburb: 'HEIDELBERG', postcode: '3084', state: 'VIC' },
  { suburb: 'HOPPERS CROSSING', postcode: '3029', state: 'VIC' },
  { suburb: 'IVANHOE', postcode: '3079', state: 'VIC' },
  { suburb: 'KENSINGTON', postcode: '3031', state: 'VIC' },
  { suburb: 'KEW', postcode: '3101', state: 'VIC' },
  { suburb: 'LAVERTON', postcode: '3028', state: 'VIC' },
  { suburb: 'MALVERN', postcode: '3144', state: 'VIC' },
  { suburb: 'MELBOURNE', postcode: '3000', state: 'VIC' },
  { suburb: 'MELTON', postcode: '3337', state: 'VIC' },
  { suburb: 'MENTONE', postcode: '3194', state: 'VIC' },
  { suburb: 'MILDURA', postcode: '3500', state: 'VIC' },
  { suburb: 'MITCHAM', postcode: '3132', state: 'VIC' },
  { suburb: 'MOONEE PONDS', postcode: '3039', state: 'VIC' },
  { suburb: 'MORDIALLOC', postcode: '3195', state: 'VIC' },
  { suburb: 'MORWELL', postcode: '3840', state: 'VIC' },
  { suburb: 'MOUNT WAVERLEY', postcode: '3149', state: 'VIC' },
  { suburb: 'NEWPORT', postcode: '3015', state: 'VIC' },
  { suburb: 'NORTH MELBOURNE', postcode: '3051', state: 'VIC' },
  { suburb: 'NORTHCOTE', postcode: '3070', state: 'VIC' },
  { suburb: 'OAKLEIGH', postcode: '3166', state: 'VIC' },
  { suburb: 'PAKENHAM', postcode: '3810', state: 'VIC' },
  { suburb: 'PARKVILLE', postcode: '3052', state: 'VIC' },
  { suburb: 'PORT MELBOURNE', postcode: '3207', state: 'VIC' },
  { suburb: 'PRAHRAN', postcode: '3181', state: 'VIC' },
  { suburb: 'PRESTON', postcode: '3072', state: 'VIC' },
  { suburb: 'RICHMOND', postcode: '3121', state: 'VIC' },
  { suburb: 'RINGWOOD', postcode: '3134', state: 'VIC' },
  { suburb: 'SHEPPARTON', postcode: '3630', state: 'VIC' },
  { suburb: 'SOUTH MELBOURNE', postcode: '3205', state: 'VIC' },
  { suburb: 'SOUTH YARRA', postcode: '3141', state: 'VIC' },
  { suburb: 'SOUTHBANK', postcode: '3006', state: 'VIC' },
  { suburb: 'ST ALBANS', postcode: '3021', state: 'VIC' },
  { suburb: 'ST KILDA', postcode: '3182', state: 'VIC' },
  { suburb: 'SUNBURY', postcode: '3429', state: 'VIC' },
  { suburb: 'SUNSHINE', postcode: '3020', state: 'VIC' },
  { suburb: 'TAYLORS LAKES', postcode: '3038', state: 'VIC' },
  { suburb: 'TEMPLESTOWE', postcode: '3106', state: 'VIC' },
  { suburb: 'THORNBURY', postcode: '3071', state: 'VIC' },
  { suburb: 'TOORAK', postcode: '3142', state: 'VIC' },
  { suburb: 'TRARALGON', postcode: '3844', state: 'VIC' },
  { suburb: 'WANTIRNA', postcode: '3152', state: 'VIC' },
  { suburb: 'WARRAGUL', postcode: '3820', state: 'VIC' },
  { suburb: 'WARRNAMBOOL', postcode: '3280', state: 'VIC' },
  { suburb: 'WERRIBEE', postcode: '3030', state: 'VIC' },
  { suburb: 'WEST MELBOURNE', postcode: '3003', state: 'VIC' },
  { suburb: 'WHEELERS HILL', postcode: '3150', state: 'VIC' },
  { suburb: 'WILLIAMSTOWN', postcode: '3016', state: 'VIC' },
  { suburb: 'WINDSOR', postcode: '3181', state: 'VIC' },
  { suburb: 'YARRAVILLE', postcode: '3013', state: 'VIC' },

  // ─── QLD ─────────────────────────────────────────────────────────────────
  { suburb: 'AIRLIE BEACH', postcode: '4802', state: 'QLD' },
  { suburb: 'ALBANY CREEK', postcode: '4035', state: 'QLD' },
  { suburb: 'ALBION', postcode: '4010', state: 'QLD' },
  { suburb: 'ANNERLEY', postcode: '4103', state: 'QLD' },
  { suburb: 'ASCOT', postcode: '4007', state: 'QLD' },
  { suburb: 'ASHGROVE', postcode: '4060', state: 'QLD' },
  { suburb: 'ASPLEY', postcode: '4034', state: 'QLD' },
  { suburb: 'BEENLEIGH', postcode: '4207', state: 'QLD' },
  { suburb: 'BENOWA', postcode: '4217', state: 'QLD' },
  { suburb: 'BIRTINYA', postcode: '4575', state: 'QLD' },
  { suburb: 'BOWEN HILLS', postcode: '4006', state: 'QLD' },
  { suburb: 'BRISBANE', postcode: '4000', state: 'QLD' },
  { suburb: 'BROADBEACH', postcode: '4218', state: 'QLD' },
  { suburb: 'BUDERIM', postcode: '4556', state: 'QLD' },
  { suburb: 'BULIMBA', postcode: '4171', state: 'QLD' },
  { suburb: 'BUNDABERG', postcode: '4670', state: 'QLD' },
  { suburb: 'BURLEIGH HEADS', postcode: '4220', state: 'QLD' },
  { suburb: 'CABOOLTURE', postcode: '4510', state: 'QLD' },
  { suburb: 'CAIRNS', postcode: '4870', state: 'QLD' },
  { suburb: 'CALOUNDRA', postcode: '4551', state: 'QLD' },
  { suburb: 'CANNON HILL', postcode: '4170', state: 'QLD' },
  { suburb: 'CAPALABA', postcode: '4157', state: 'QLD' },
  { suburb: 'CARINDALE', postcode: '4152', state: 'QLD' },
  { suburb: 'CARSELDINE', postcode: '4034', state: 'QLD' },
  { suburb: 'CHERMSIDE', postcode: '4032', state: 'QLD' },
  { suburb: 'CLEVELAND', postcode: '4163', state: 'QLD' },
  { suburb: 'COOLANGATTA', postcode: '4225', state: 'QLD' },
  { suburb: 'COOMERA', postcode: '4209', state: 'QLD' },
  { suburb: 'COORPAROO', postcode: '4151', state: 'QLD' },
  { suburb: 'DALBY', postcode: '4405', state: 'QLD' },
  { suburb: 'DARRA', postcode: '4076', state: 'QLD' },
  { suburb: 'DECEPTION BAY', postcode: '4508', state: 'QLD' },
  { suburb: 'EAGLE FARM', postcode: '4009', state: 'QLD' },
  { suburb: 'EIGHT MILE PLAINS', postcode: '4113', state: 'QLD' },
  { suburb: 'EMERALD', postcode: '4720', state: 'QLD' },
  { suburb: 'EVERTON HILLS', postcode: '4053', state: 'QLD' },
  { suburb: 'FORTITUDE VALLEY', postcode: '4006', state: 'QLD' },
  { suburb: 'GLADSTONE', postcode: '4680', state: 'QLD' },
  { suburb: 'GOLD COAST', postcode: '4217', state: 'QLD' },
  { suburb: 'GYMPIE', postcode: '4570', state: 'QLD' },
  { suburb: 'HAMILTON', postcode: '4007', state: 'QLD' },
  { suburb: 'HELENSVALE', postcode: '4212', state: 'QLD' },
  { suburb: 'HERVEY BAY', postcode: '4655', state: 'QLD' },
  { suburb: 'HOLLAND PARK', postcode: '4121', state: 'QLD' },
  { suburb: 'INDOOROOPILLY', postcode: '4068', state: 'QLD' },
  { suburb: 'IPSWICH', postcode: '4305', state: 'QLD' },
  { suburb: 'JINDALEE', postcode: '4074', state: 'QLD' },
  { suburb: 'KALLANGUR', postcode: '4503', state: 'QLD' },
  { suburb: 'KANGAROO POINT', postcode: '4169', state: 'QLD' },
  { suburb: 'KINGAROY', postcode: '4610', state: 'QLD' },
  { suburb: 'LOGAN CENTRAL', postcode: '4114', state: 'QLD' },
  { suburb: 'LOGANHOLME', postcode: '4129', state: 'QLD' },
  { suburb: 'MACKAY', postcode: '4740', state: 'QLD' },
  { suburb: 'MAROOCHYDORE', postcode: '4558', state: 'QLD' },
  { suburb: 'MARYBOROUGH', postcode: '4650', state: 'QLD' },
  { suburb: 'MERMAID BEACH', postcode: '4218', state: 'QLD' },
  { suburb: 'MILTON', postcode: '4064', state: 'QLD' },
  { suburb: 'MOOLOOLABA', postcode: '4557', state: 'QLD' },
  { suburb: 'MORANBAH', postcode: '4744', state: 'QLD' },
  { suburb: 'MORNINGSIDE', postcode: '4170', state: 'QLD' },
  { suburb: 'MOUNT GRAVATT', postcode: '4122', state: 'QLD' },
  { suburb: 'MOUNT ISA', postcode: '4825', state: 'QLD' },
  { suburb: 'MURARRIE', postcode: '4172', state: 'QLD' },
  { suburb: 'NAMBOUR', postcode: '4560', state: 'QLD' },
  { suburb: 'NEW FARM', postcode: '4005', state: 'QLD' },
  { suburb: 'NOOSA HEADS', postcode: '4567', state: 'QLD' },
  { suburb: 'NUDGEE', postcode: '4014', state: 'QLD' },
  { suburb: 'PADDINGTON', postcode: '4064', state: 'QLD' },
  { suburb: 'PALM BEACH', postcode: '4221', state: 'QLD' },
  { suburb: 'REDCLIFFE', postcode: '4020', state: 'QLD' },
  { suburb: 'REDLAND BAY', postcode: '4165', state: 'QLD' },
  { suburb: 'ROBINA', postcode: '4226', state: 'QLD' },
  { suburb: 'ROCKHAMPTON', postcode: '4700', state: 'QLD' },
  { suburb: 'ROCKLEA', postcode: '4106', state: 'QLD' },
  { suburb: 'ROMA', postcode: '4455', state: 'QLD' },
  { suburb: 'SOUTH BANK', postcode: '4101', state: 'QLD' },
  { suburb: 'SOUTHPORT', postcode: '4215', state: 'QLD' },
  { suburb: 'SPRING HILL', postcode: '4000', state: 'QLD' },
  { suburb: 'SPRINGFIELD', postcode: '4300', state: 'QLD' },
  { suburb: 'STAFFORD', postcode: '4053', state: 'QLD' },
  { suburb: 'STRATHPINE', postcode: '4500', state: 'QLD' },
  { suburb: 'SUNNYBANK', postcode: '4109', state: 'QLD' },
  { suburb: 'SURFERS PARADISE', postcode: '4217', state: 'QLD' },
  { suburb: 'TENERIFFE', postcode: '4005', state: 'QLD' },
  { suburb: 'THE GAP', postcode: '4061', state: 'QLD' },
  { suburb: 'TOOWONG', postcode: '4066', state: 'QLD' },
  { suburb: 'TOOWOOMBA', postcode: '4350', state: 'QLD' },
  { suburb: 'TOWNSVILLE', postcode: '4810', state: 'QLD' },
  { suburb: 'UPPER MOUNT GRAVATT', postcode: '4122', state: 'QLD' },
  { suburb: 'VIRGINIA', postcode: '4014', state: 'QLD' },
  { suburb: 'WARWICK', postcode: '4370', state: 'QLD' },
  { suburb: 'WEST END', postcode: '4101', state: 'QLD' },
  { suburb: 'WOOLLOONGABBA', postcode: '4102', state: 'QLD' },
  { suburb: 'WYNNUM', postcode: '4178', state: 'QLD' },
  { suburb: 'YEPPOON', postcode: '4703', state: 'QLD' },

  // ─── SA ──────────────────────────────────────────────────────────────────
  { suburb: 'ADELAIDE', postcode: '5000', state: 'SA' },
  { suburb: 'BURNSIDE', postcode: '5066', state: 'SA' },
  { suburb: 'CAMPBELLTOWN', postcode: '5074', state: 'SA' },
  { suburb: 'ELIZABETH', postcode: '5112', state: 'SA' },
  { suburb: 'GAWLER', postcode: '5118', state: 'SA' },
  { suburb: 'GLENELG', postcode: '5045', state: 'SA' },
  { suburb: 'HENLEY BEACH', postcode: '5022', state: 'SA' },
  { suburb: 'HINDMARSH', postcode: '5007', state: 'SA' },
  { suburb: 'KENT TOWN', postcode: '5067', state: 'SA' },
  { suburb: 'MAGILL', postcode: '5072', state: 'SA' },
  { suburb: 'MARION', postcode: '5043', state: 'SA' },
  { suburb: 'MAWSON LAKES', postcode: '5095', state: 'SA' },
  { suburb: 'MILE END', postcode: '5031', state: 'SA' },
  { suburb: 'MODBURY', postcode: '5092', state: 'SA' },
  { suburb: 'MOUNT GAMBIER', postcode: '5290', state: 'SA' },
  { suburb: 'NORTH ADELAIDE', postcode: '5006', state: 'SA' },
  { suburb: 'NORWOOD', postcode: '5067', state: 'SA' },
  { suburb: 'PORT ADELAIDE', postcode: '5015', state: 'SA' },
  { suburb: 'PORT AUGUSTA', postcode: '5700', state: 'SA' },
  { suburb: 'PORT LINCOLN', postcode: '5606', state: 'SA' },
  { suburb: 'PORT PIRIE', postcode: '5540', state: 'SA' },
  { suburb: 'PROSPECT', postcode: '5082', state: 'SA' },
  { suburb: 'RENMARK', postcode: '5341', state: 'SA' },
  { suburb: 'SALISBURY', postcode: '5108', state: 'SA' },
  { suburb: 'SEMAPHORE', postcode: '5019', state: 'SA' },
  { suburb: 'STIRLING', postcode: '5152', state: 'SA' },
  { suburb: 'UNLEY', postcode: '5061', state: 'SA' },
  { suburb: 'WHYALLA', postcode: '5600', state: 'SA' },

  // ─── WA ──────────────────────────────────────────────────────────────────
  { suburb: 'ALBANY', postcode: '6330', state: 'WA' },
  { suburb: 'ARMADALE', postcode: '6112', state: 'WA' },
  { suburb: 'BAYSWATER', postcode: '6053', state: 'WA' },
  { suburb: 'BELMONT', postcode: '6104', state: 'WA' },
  { suburb: 'BUNBURY', postcode: '6230', state: 'WA' },
  { suburb: 'BUSSELTON', postcode: '6280', state: 'WA' },
  { suburb: 'CANNINGTON', postcode: '6107', state: 'WA' },
  { suburb: 'CLAREMONT', postcode: '6010', state: 'WA' },
  { suburb: 'COTTESLOE', postcode: '6011', state: 'WA' },
  { suburb: 'EAST PERTH', postcode: '6004', state: 'WA' },
  { suburb: 'FREMANTLE', postcode: '6160', state: 'WA' },
  { suburb: 'GERALDTON', postcode: '6530', state: 'WA' },
  { suburb: 'JOONDALUP', postcode: '6027', state: 'WA' },
  { suburb: 'KALAMUNDA', postcode: '6076', state: 'WA' },
  { suburb: 'KALGOORLIE', postcode: '6430', state: 'WA' },
  { suburb: 'KARRATHA', postcode: '6714', state: 'WA' },
  { suburb: 'LEEDERVILLE', postcode: '6007', state: 'WA' },
  { suburb: 'MANDURAH', postcode: '6210', state: 'WA' },
  { suburb: 'MARGARET RIVER', postcode: '6285', state: 'WA' },
  { suburb: 'MIDLAND', postcode: '6056', state: 'WA' },
  { suburb: 'MIRRABOOKA', postcode: '6061', state: 'WA' },
  { suburb: 'MORLEY', postcode: '6062', state: 'WA' },
  { suburb: 'MOUNT LAWLEY', postcode: '6050', state: 'WA' },
  { suburb: 'MURDOCH', postcode: '6150', state: 'WA' },
  { suburb: 'NEDLANDS', postcode: '6009', state: 'WA' },
  { suburb: 'NORTHBRIDGE', postcode: '6003', state: 'WA' },
  { suburb: 'OSBORNE PARK', postcode: '6017', state: 'WA' },
  { suburb: 'PERTH', postcode: '6000', state: 'WA' },
  { suburb: 'PORT HEDLAND', postcode: '6721', state: 'WA' },
  { suburb: 'ROCKINGHAM', postcode: '6168', state: 'WA' },
  { suburb: 'SCARBOROUGH', postcode: '6019', state: 'WA' },
  { suburb: 'SOUTH PERTH', postcode: '6151', state: 'WA' },
  { suburb: 'SUBIACO', postcode: '6008', state: 'WA' },
  { suburb: 'VICTORIA PARK', postcode: '6100', state: 'WA' },
  { suburb: 'WEMBLEY', postcode: '6014', state: 'WA' },
  { suburb: 'WEST PERTH', postcode: '6005', state: 'WA' },

  // ─── TAS ─────────────────────────────────────────────────────────────────
  { suburb: 'BATTERY POINT', postcode: '7004', state: 'TAS' },
  { suburb: 'BURNIE', postcode: '7320', state: 'TAS' },
  { suburb: 'DEVONPORT', postcode: '7310', state: 'TAS' },
  { suburb: 'GLENORCHY', postcode: '7010', state: 'TAS' },
  { suburb: 'HOBART', postcode: '7000', state: 'TAS' },
  { suburb: 'KINGSTON', postcode: '7050', state: 'TAS' },
  { suburb: 'LAUNCESTON', postcode: '7250', state: 'TAS' },
  { suburb: 'MOONAH', postcode: '7009', state: 'TAS' },
  { suburb: 'NEW NORFOLK', postcode: '7140', state: 'TAS' },
  { suburb: 'NORTH HOBART', postcode: '7000', state: 'TAS' },
  { suburb: 'SANDY BAY', postcode: '7005', state: 'TAS' },
  { suburb: 'SOUTH HOBART', postcode: '7004', state: 'TAS' },
  { suburb: 'ULVERSTONE', postcode: '7315', state: 'TAS' },

  // ─── NT ──────────────────────────────────────────────────────────────────
  { suburb: 'ALICE SPRINGS', postcode: '0870', state: 'NT' },
  { suburb: 'CASUARINA', postcode: '0810', state: 'NT' },
  { suburb: 'DARWIN', postcode: '0800', state: 'NT' },
  { suburb: 'KATHERINE', postcode: '0850', state: 'NT' },
  { suburb: 'PALMERSTON', postcode: '0830', state: 'NT' },
  { suburb: 'TENNANT CREEK', postcode: '0860', state: 'NT' },
];

// Build lookup index. Multiple suburbs share names across states (e.g.,
// CAMPBELLTOWN exists in NSW + SA; RICHMOND in NSW + VIC + QLD); we keep the
// FIRST entry for direct lookup but expose `findAllSuburbsByName()` to retrieve
// every state match so the UI can disambiguate when the user picks a state.
const SUBURB_INDEX: Map<string, SuburbEntry[]> = (() => {
  const m = new Map<string, SuburbEntry[]>();
  for (const entry of AU_SUBURBS) {
    const key = entry.suburb;
    if (!m.has(key)) m.set(key, []);
    m.get(key)!.push(entry);
  }
  return m;
})();

/**
 * Look up postcode + state from a suburb name. Case-insensitive, trims input.
 * Returns null if suburb not found in our curated dataset.
 *
 * If the suburb name appears in multiple states (e.g. CAMPBELLTOWN), pass
 * `state` to disambiguate; otherwise the first match is returned.
 */
export function lookupPostcodeBySuburb(
  suburbName: string,
  state?: string
): SuburbEntry | null {
  const key = suburbName.trim().toUpperCase();
  if (!key) return null;
  const matches = SUBURB_INDEX.get(key);
  if (!matches || matches.length === 0) return null;
  if (state) {
    const stateUpper = state.trim().toUpperCase();
    const stateMatch = matches.find(m => m.state === stateUpper);
    if (stateMatch) return stateMatch;
  }
  return matches[0];
}

/**
 * Return every dataset entry whose suburb name exactly matches (across states).
 * Useful for the modal to surface "Did you mean Richmond NSW or Richmond VIC?".
 */
export function findAllSuburbsByName(suburbName: string): SuburbEntry[] {
  const key = suburbName.trim().toUpperCase();
  if (!key) return [];
  return SUBURB_INDEX.get(key) ?? [];
}

/**
 * Prefix search for a typeahead. Returns up to `limit` suburbs whose names
 * start with the query (case-insensitive). Ordered alphabetically.
 */
export function searchSuburbs(prefix: string, limit = 10): SuburbEntry[] {
  const key = prefix.trim().toUpperCase();
  if (key.length < 2) return [];
  const out: SuburbEntry[] = [];
  for (const entry of AU_SUBURBS) {
    if (entry.suburb.startsWith(key)) {
      out.push(entry);
      if (out.length >= limit) break;
    }
  }
  return out;
}

// Exported for tests / debugging — count of entries in the dataset.
export const AU_SUBURB_COUNT = AU_SUBURBS.length;
