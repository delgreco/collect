SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `collect`
--

-- --------------------------------------------------------

--
-- Table structure for table `comic_boxes`
--

CREATE TABLE `comic_boxes` (
  `id` int NOT NULL,
  `number` int NOT NULL,
  `start_comic_id` int NOT NULL,
  `end_comic_id` int NOT NULL,
  `notes` varchar(255) NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `comic_grades`
--

CREATE TABLE `comic_grades` (
  `id` int NOT NULL,
  `grade` varchar(100) NOT NULL,
  `grade_abbrev` varchar(10) NOT NULL,
  `description` text,
  `cgc_number` decimal(19,1) NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `images`
--

CREATE TABLE `images` (
  `id` int NOT NULL,
  `item_id` int NOT NULL,
  `notes` text,
  `extension` varchar(10) CHARACTER SET latin1 COLLATE latin1_swedish_ci NOT NULL DEFAULT 'JPG',
  `main` tinyint(1) NOT NULL DEFAULT '1' COMMENT 'used as main display image',
  `stock` tinyint(1) NOT NULL DEFAULT '1'
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `items`
--

CREATE TABLE `items` (
  `id` int NOT NULL,
  `volume` varchar(20) CHARACTER SET latin1 COLLATE latin1_swedish_ci DEFAULT NULL,
  `issue_num` varchar(8) NOT NULL DEFAULT '0',
  `year` varchar(4) NOT NULL DEFAULT '',
  `title_id` int NOT NULL,
  `thumb_url` varchar(255) NOT NULL DEFAULT '',
  `image_page_url` varchar(255) NOT NULL DEFAULT '',
  `publisher` varchar(100) CHARACTER SET latin1 COLLATE latin1_swedish_ci DEFAULT 'Marvel',
  `notes` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `storage` varchar(50) CHARACTER SET latin1 COLLATE latin1_swedish_ci NOT NULL DEFAULT '0',
  `grade_id` int DEFAULT NULL,
  `PSA_grade_id` int DEFAULT NULL,
  `added` datetime DEFAULT NULL,
  `beast_appear` enum('yes','no') NOT NULL DEFAULT 'no',
  `beast_cover` enum('yes','no') NOT NULL DEFAULT 'no',
  `value` decimal(10,2) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `PSA_grades`
--

CREATE TABLE `PSA_grades` (
  `id` int NOT NULL,
  `grade` varchar(100) NOT NULL,
  `grade_abbrev` varchar(10) NOT NULL,
  `description` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `PSA_number` int DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `titles`
--

CREATE TABLE `titles` (
  `id` int NOT NULL,
  `title` varchar(255) NOT NULL,
  `type` enum('comic','card','magazine','book') NOT NULL DEFAULT 'comic'
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `comic_boxes`
--
ALTER TABLE `comic_boxes`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `comic_grades`
--
ALTER TABLE `comic_grades`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `images`
--
ALTER TABLE `images`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `items`
--
ALTER TABLE `items`
  ADD PRIMARY KEY (`id`),
  ADD KEY `bomb` (`grade_id`,`title_id`,`year`) USING BTREE;

--
-- Indexes for table `PSA_grades`
--
ALTER TABLE `PSA_grades`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `titles`
--
ALTER TABLE `titles`
  ADD PRIMARY KEY (`id`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `comic_boxes`
--
ALTER TABLE `comic_boxes`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `comic_grades`
--
ALTER TABLE `comic_grades`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `images`
--
ALTER TABLE `images`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `items`
--
ALTER TABLE `items`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `PSA_grades`
--
ALTER TABLE `PSA_grades`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `titles`
--
ALTER TABLE `titles`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
